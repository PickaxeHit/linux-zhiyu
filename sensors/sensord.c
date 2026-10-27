// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Minimal net.hadess.SensorProxy service backed by sensh/SNS Client.
 *
 * No IIO involved: this is the userspace/HAL-style path.  sensh does the
 * SNS Client QMI/protobuf work; this daemon publishes the desktop
 * SensorProxy D-Bus API.
 */
#include <fcntl.h>
#include <gio/gio.h>
#include <glib.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUS_NAME "net.hadess.SensorProxy"
#define OBJ_PATH "/net/hadess/SensorProxy"
#define IFACE    "net.hadess.SensorProxy"
#define SENSH    "/usr/local/bin/sensh"

static const gchar introspection_xml[] =
	"<node>"
	"  <interface name='net.hadess.SensorProxy'>"
	"    <method name='ClaimAccelerometer'/>"
	"    <method name='ReleaseAccelerometer'/>"
	"    <method name='ClaimLight'/>"
	"    <method name='ReleaseLight'/>"
	"    <method name='ClaimProximity'/>"
	"    <method name='ReleaseProximity'/>"
	"    <property name='HasAccelerometer' type='b' access='read'/>"
	"    <property name='AccelerometerOrientation' type='s' access='read'/>"
	"    <property name='AccelerometerTilt' type='s' access='read'/>"
	"    <property name='HasAmbientLight' type='b' access='read'/>"
	"    <property name='LightLevelUnit' type='s' access='read'/>"
	"    <property name='LightLevel' type='d' access='read'/>"
	"    <property name='HasProximity' type='b' access='read'/>"
	"    <property name='ProximityNear' type='b' access='read'/>"
	"  </interface>"
	"</node>";

typedef enum {
	STREAM_LIGHT,
	STREAM_ACCEL,
	STREAM_GYRO,
} StreamType;

typedef struct Sensord Sensord;

typedef struct {
	Sensord *self;
	StreamType type;
	GSubprocess *proc;
	GDataInputStream *out;
} Stream;

struct Sensord {
	GDBusConnection *conn;
	guint owner_id;
	guint reg_id;

	gboolean has_light;
	gdouble light;
	gboolean has_accel;
	gboolean accel_claimed;
	gchar *orientation;

	/* accelerometer filter / Android-style orientation state */
	gboolean filter_init;
	gdouble fx, fy, fz;
	gint64 last_sample_us;
	gboolean flat;
	gint64 flat_since_us;
	gint64 flat_end_us;
	gint64 accel_until_us;
	gint current_quadrant;
	gint candidate_quadrant;
	gint64 candidate_since_us;

	Stream *streams[3];
};

static void set_orientation(Sensord *self, const gchar *orientation);

static void emit_property(Sensord *self, const gchar *name, GVariant *value)
{
	GVariantBuilder changed;
	GVariant *invalid;

	g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&changed, "{sv}", name, value);
	invalid = g_variant_new_strv(NULL, 0);
	g_dbus_connection_emit_signal(self->conn, NULL, OBJ_PATH,
				      "org.freedesktop.DBus.Properties",
				      "PropertiesChanged",
				      g_variant_new("(sa{sv}@as)", IFACE,
						    &changed, invalid),
				      NULL);
}

static const gchar *const quadrant_names[4] = {
	"left-up",	/*  0 deg: +y portrait */
	"bottom-up",	/* 90 deg: -x landscape 180 */
	"right-up",	/* 180 deg: -y portrait 180 */
	"normal",	/* 270 deg: +x landscape */
};

static void accel_process(Sensord *self, gdouble x, gdouble y, gdouble z)
{
	const gdouble g = 9.80665;
	const gdouble rad_to_deg = 57.29577951308232;
	gint64 now = g_get_monotonic_time();
	gdouble dt_ms;
	gdouble alpha;
	gdouble magnitude;
	gdouble tilt;
	gdouble angle;
	gint quadrant;
	gdouble center;
	gdouble diff;

	if (!self->filter_init || now - self->last_sample_us > 1000000) {
		self->fx = x;
		self->fy = y;
		self->fz = z;
		self->filter_init = TRUE;
	} else {
		dt_ms = (now - self->last_sample_us) / 1000.0;
		alpha = dt_ms / (200.0 + dt_ms);
		self->fx += alpha * (x - self->fx);
		self->fy += alpha * (y - self->fy);
		self->fz += alpha * (z - self->fz);
	}
	self->last_sample_us = now;

	magnitude = sqrt(self->fx * self->fx + self->fy * self->fy +
			 self->fz * self->fz);

	/* Ignore samples while the device is being accelerated. */
	if (magnitude < g - 4.0 || magnitude > g + 4.0) {
		self->candidate_quadrant = -1;
		self->accel_until_us = now + 500000;
		return;
	}
	if (now < self->accel_until_us) {
		self->candidate_quadrant = -1;
		return;
	}

	tilt = asin(CLAMP(self->fz / magnitude, -1.0, 1.0)) * rad_to_deg;

	/*
	 * Near horizontal: ignore orientation changes.  This is Android's
	 * flat/overhead handling: while the device is on a table, the x/y
	 * projection is unstable and must not rotate the screen.
	 */
	if (fabs(tilt) > 75.0) {
		if (self->flat_since_us == 0)
			self->flat_since_us = now;
		if (now - self->flat_since_us >= 800000)
			self->flat = TRUE;
		self->candidate_quadrant = -1;
		return;
	}

	self->flat_since_us = 0;
	if (self->flat) {
		self->flat = FALSE;
		self->flat_end_us = now;
	}
	if (now < self->flat_end_us + 500000) {
		self->candidate_quadrant = -1;
		return;
	}

	/*
	 * Android uses atan2(-x, y) to get the rotation angle.  TB378FC is
	 * landscape-native, so the quadrant mapping is rotated relative to
	 * the usual iio-sensor-proxy/portrait mapping.
	 */
	angle = atan2(-self->fx, self->fy) * rad_to_deg;
	if (angle < 0)
		angle += 360.0;
	quadrant = ((gint)((angle + 45.0) / 90.0)) % 4;

	if (self->current_quadrant < 0) {
		self->current_quadrant = quadrant;
		self->candidate_quadrant = -1;
		set_orientation(self, quadrant_names[quadrant]);
		return;
	}

	if (quadrant == self->current_quadrant) {
		self->candidate_quadrant = -1;
		return;
	}

	/* Hysteresis: require moving well past the current quadrant. */
	center = self->current_quadrant * 90.0;
	diff = fabs(angle - center);
	if (diff > 180.0)
		diff = 360.0 - diff;
	if (diff < 60.0) {
		self->candidate_quadrant = -1;
		return;
	}

	if (quadrant != self->candidate_quadrant) {
		self->candidate_quadrant = quadrant;
		self->candidate_since_us = now;
	}
	if (now - self->candidate_since_us < 300000)
		return;

	self->current_quadrant = quadrant;
	self->candidate_quadrant = -1;
	set_orientation(self, quadrant_names[quadrant]);
}

static void set_spk_rotation(const gchar *orientation)
{
	static const struct {
		const gchar *orientation;
		const gchar *rotation;
	} map[] = {
		/* TB378FC: x gravity is landscape, y gravity is portrait. */
		{ "normal", "0" },
		{ "bottom-up", "180" },
		{ "left-up", "90" },
		{ "right-up", "270" },
	};
	const gchar *rotation = NULL;
	const gchar *path = "/sys/module/q6apm_lpass_dais/parameters/spk_rotation";
	int fd;
	gsize i;

	for (i = 0; i < G_N_ELEMENTS(map); i++) {
		if (g_strcmp0(orientation, map[i].orientation) == 0) {
			rotation = map[i].rotation;
			break;
		}
	}
	if (!rotation)
		return;

	fd = open(path, O_WRONLY);
	if (fd < 0)
		return;
	if (write(fd, rotation, strlen(rotation)) < 0)
		g_warning("failed to write %s", path);
	close(fd);
}

static void set_orientation(Sensord *self, const gchar *orientation)
{
	if (g_strcmp0(self->orientation, orientation) == 0)
		return;
	g_free(self->orientation);
	self->orientation = g_strdup(orientation);
	if (self->accel_claimed)
		set_spk_rotation(self->orientation);
	if (self->conn)
		emit_property(self, "AccelerometerOrientation",
			      g_variant_new_string(self->orientation));
}

static void read_stream_cb(GObject *source, GAsyncResult *res, gpointer user_data)
{
	Stream *stream = user_data;
	GDataInputStream *dis = G_DATA_INPUT_STREAM(source);
	GError *error = NULL;
	gsize len = 0;
	gchar *line;

	line = g_data_input_stream_read_line_finish(dis, res, &len, &error);
	if (!line) {
		if (error) {
			g_warning("sensh stream read: %s", error->message);
			g_error_free(error);
		}
		return;
	}

	const gchar *p = strstr(line, "sensor data:");
	if (p) {
		p += strlen("sensor data:");
		if (stream->type == STREAM_LIGHT) {
			gdouble value = g_ascii_strtod(p, NULL);
			if (value >= 0.0) {
				stream->self->has_light = TRUE;
				if (value != stream->self->light) {
					stream->self->light = value;
					emit_property(stream->self, "LightLevel",
						      g_variant_new_double(value));
				}
			}
		} else {
			gdouble x = 0, y = 0, z = 0;
			if (sscanf(p, "%lf,%lf,%lf", &x, &y, &z) == 3) {
				if (stream->type == STREAM_ACCEL) {
					stream->self->has_accel = TRUE;
					accel_process(stream->self, x, y, z);
				}
			}
		}
	}

	g_free(line);
	g_data_input_stream_read_line_async(dis, G_PRIORITY_DEFAULT, NULL,
					    read_stream_cb, stream);
}

static gchar *lookup_suid(const gchar *type)
{
	gchar *cmd = g_strdup_printf("timeout 2 %s lookup %s", SENSH, type);
	gchar *out = NULL;
	gint status = 0;
	GError *error = NULL;
	gchar *suid = NULL;

	if (!g_spawn_command_line_sync(cmd, &out, NULL, &status, &error)) {
		g_warning("sensh lookup %s: %s", type, error->message);
		g_error_free(error);
		g_free(cmd);
		return NULL;
	}
	if (out) {
		gchar *p = strstr(out, "sensor found:");
		if (p) {
			p += strlen("sensor found:");
			while (*p == ' ' || *p == '\t')
				p++;
			gchar *end = p;
			while (*end && *end != '\n' && *end != ' ' && *end != '\t')
				end++;
			if (end != p)
				suid = g_strndup(p, end - p);
		}
	}
	g_free(out);
	g_free(cmd);
	return suid;
}

static Stream *start_stream(Sensord *self, StreamType type, const gchar *suid,
			    const gchar *rate)
{
	GError *error = NULL;
	Stream *stream = g_new0(Stream, 1);

	stream->self = self;
	stream->type = type;
	stream->proc = g_subprocess_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE |
					G_SUBPROCESS_FLAGS_STDERR_SILENCE,
					&error, SENSH, "config", suid, rate, NULL);
	if (!stream->proc) {
		g_warning("sensh config %s: %s", suid, error->message);
		g_error_free(error);
		g_free(stream);
		return NULL;
	}
	stream->out = g_data_input_stream_new(
		g_subprocess_get_stdout_pipe(stream->proc));
	g_data_input_stream_set_newline_type(stream->out,
					     G_DATA_STREAM_NEWLINE_TYPE_ANY);
	g_data_input_stream_read_line_async(stream->out, G_PRIORITY_DEFAULT,
					    NULL, read_stream_cb, stream);
	return stream;
}

static void start_sensor(Sensord *self)
{
	gchar *light, *accel, *gyro;

	self->has_light = TRUE;
	self->has_accel = TRUE;
	self->current_quadrant = -1;

	light = lookup_suid("ambient_light");
	if (light) {
		g_message("ambient_light SUID %s", light);
		self->streams[STREAM_LIGHT] =
			start_stream(self, STREAM_LIGHT, light, "10");
		g_free(light);
	} else {
		self->has_light = FALSE;
	}

	accel = lookup_suid("accel");
	if (accel) {
		g_message("accel SUID %s", accel);
		self->streams[STREAM_ACCEL] =
			start_stream(self, STREAM_ACCEL, accel, "50");
		g_free(accel);
	} else {
		self->has_accel = FALSE;
	}

	gyro = lookup_suid("gyro");
	if (gyro) {
		g_message("gyro SUID %s", gyro);
		self->streams[STREAM_GYRO] =
			start_stream(self, STREAM_GYRO, gyro, "50");
		g_free(gyro);
	}
}

static GVariant *get_property(GDBusConnection *connection,
			      const gchar *sender, const gchar *object_path,
			      const gchar *interface_name,
			      const gchar *property_name, GError **error,
			      gpointer user_data)
{
	Sensord *self = user_data;

	if (g_strcmp0(property_name, "HasAccelerometer") == 0)
		return g_variant_new_boolean(self->has_accel);
	if (g_strcmp0(property_name, "AccelerometerOrientation") == 0)
		return g_variant_new_string(self->orientation ?: "undefined");
	if (g_strcmp0(property_name, "AccelerometerTilt") == 0)
		return g_variant_new_string("undefined");
	if (g_strcmp0(property_name, "HasAmbientLight") == 0)
		return g_variant_new_boolean(self->has_light);
	if (g_strcmp0(property_name, "LightLevelUnit") == 0)
		return g_variant_new_string("lux");
	if (g_strcmp0(property_name, "LightLevel") == 0)
		return g_variant_new_double(self->light);
	if (g_strcmp0(property_name, "HasProximity") == 0)
		return g_variant_new_boolean(FALSE);
	if (g_strcmp0(property_name, "ProximityNear") == 0)
		return g_variant_new_boolean(FALSE);

	g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
		    "Unknown property %s", property_name);
	return NULL;
}

static void method_call(GDBusConnection *connection, const gchar *sender,
			const gchar *object_path, const gchar *interface_name,
			const gchar *method_name, GVariant *parameters,
			GDBusMethodInvocation *invocation, gpointer user_data)
{
	Sensord *self = user_data;

	if (g_strcmp0(interface_name, IFACE) == 0 &&
	    g_strcmp0(method_name, "ClaimAccelerometer") == 0) {
		self->accel_claimed = TRUE;
		/* Catch up with the orientation already known when the consumer
		 * enables automatic rotation after sensord started. */
		if (self->orientation)
			set_spk_rotation(self->orientation);
	} else if (g_strcmp0(interface_name, IFACE) == 0 &&
		   g_strcmp0(method_name, "ReleaseAccelerometer") == 0) {
		/* Keep the last matrix.  The display is fixed now; changing the
		 * speaker mapping here would desynchronise audio and screen. */
		self->accel_claimed = FALSE;
	}

	g_dbus_method_invocation_return_value(invocation, NULL);
}

static const GDBusInterfaceVTable vtable = {
	.method_call = method_call,
	.get_property = get_property,
	.set_property = NULL,
};

static void on_bus_acquired(GDBusConnection *connection, const gchar *name,
			    gpointer user_data)
{
	Sensord *self = user_data;
	GDBusNodeInfo *info;
	GError *error = NULL;

	info = g_dbus_node_info_new_for_xml(introspection_xml, &error);
	if (!info) {
		g_warning("introspection: %s", error->message);
		g_error_free(error);
		return;
	}
	self->conn = g_object_ref(connection);
	self->reg_id = g_dbus_connection_register_object(
		connection, OBJ_PATH, info->interfaces[0], &vtable,
		self, NULL, &error);
	g_dbus_node_info_unref(info);
	if (!self->reg_id) {
		g_warning("register object: %s", error->message);
		g_error_free(error);
	}
}

static void on_name_acquired(GDBusConnection *connection, const gchar *name,
			     gpointer user_data)
{
	start_sensor(user_data);
}

int main(void)
{
	Sensord self = { 0 };
	GMainLoop *loop;

	loop = g_main_loop_new(NULL, FALSE);

	self.owner_id = g_bus_own_name(G_BUS_TYPE_SYSTEM, BUS_NAME,
				       G_BUS_NAME_OWNER_FLAGS_NONE,
				       on_bus_acquired, on_name_acquired, NULL,
				       &self, NULL);

	g_main_loop_run(loop);
	g_main_loop_unref(loop);
	return 0;
}
