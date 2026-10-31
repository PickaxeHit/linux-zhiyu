// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * camfeed - stream a libcamera camera into a V4L2 device (v4l2loopback).
 *
 * The tablet's cameras come up through libcamera's software ISP.  The
 * PipeWire/libcamera path only offers a fixed set of sizes, so an application
 * that speaks nothing but V4L2 (Chrome, Zoom, kamoso) cannot be given the full
 * resolution through it.  This tool configures the camera itself and writes
 * YUYV frames to a V4L2 output device:
 *
 *   camfeed -c 2 -w 3256 -h 2448 -o /dev/video19
 *
 * -c is the libcamera camera index, as enumerated by "cam -l".
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/videodev2.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <libcamera/libcamera.h>

using namespace libcamera;

static volatile sig_atomic_t stop;

static void on_signal(int)
{
	stop = 1;
}

struct Feed {
	std::shared_ptr<Camera> camera;
	Stream *stream = nullptr;
	int out = -1;
	unsigned int width = 0;
	unsigned int height = 0;
	unsigned int stride = 0;
	unsigned int frames = 0;
	std::vector<unsigned char> yuyv;
};

/* RGBA/XRGB (four bytes per pixel) to YUYV, BT.601 studio range. */
static void convert(const unsigned char *src, unsigned int stride,
		    unsigned char *dst, unsigned int width, unsigned int height)
{
	for (unsigned int y = 0; y < height; y++) {
		const unsigned char *row = src + y * stride;
		unsigned char *out = dst + y * width * 2;

		for (unsigned int x = 0; x < width; x += 2) {
			const unsigned char *p0 = row + x * 4;
			const unsigned char *p1 = row + (x + 1 < width ? x + 1 : x) * 4;

			int r = (p0[2] + p1[2]) / 2;
			int g = (p0[1] + p1[1]) / 2;
			int b = (p0[0] + p1[0]) / 2;

			int y0 = ((66 * p0[2] + 129 * p0[1] + 25 * p0[0] + 128) >> 8) + 16;
			int y1 = ((66 * p1[2] + 129 * p1[1] + 25 * p1[0] + 128) >> 8) + 16;
			int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
			int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;

			out[x * 2 + 0] = y0 < 0 ? 0 : (y0 > 255 ? 255 : y0);
			out[x * 2 + 1] = u < 0 ? 0 : (u > 255 ? 255 : u);
			out[x * 2 + 2] = y1 < 0 ? 0 : (y1 > 255 ? 255 : y1);
			out[x * 2 + 3] = v < 0 ? 0 : (v > 255 ? 255 : v);
		}
	}
}

class Handler {
public:
	explicit Handler(Feed *feed) : feed_(feed) {}

	void requestComplete(Request *request)
	{
		FrameBuffer *buffer = request->buffers().begin()->second;
		const FrameBuffer::Plane &plane = buffer->planes()[0];

		void *mem = mmap(nullptr, plane.length, PROT_READ, MAP_SHARED,
				 plane.fd.get(), 0);
		if (mem != MAP_FAILED) {
			convert(static_cast<unsigned char *>(mem), feed_->stride,
				feed_->yuyv.data(), feed_->width, feed_->height);
			if (write(feed_->out, feed_->yuyv.data(),
				  feed_->yuyv.size()) < 0 && errno != EAGAIN)
				perror("write");
			feed_->frames++;
			munmap(mem, plane.length);
		}

		request->reuse(Request::ReuseBuffers);
		if (!stop)
			feed_->camera->queueRequest(request);
	}

private:
	Feed *feed_;
};

static int set_out_format(Feed &feed)
{
	struct v4l2_format fmt = {};

	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = feed.width;
	fmt.fmt.pix.height = feed.height;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	fmt.fmt.pix.bytesperline = feed.width * 2;
	fmt.fmt.pix.sizeimage = feed.width * feed.height * 2;

	if (ioctl(feed.out, VIDIOC_S_FMT, &fmt) < 0) {
		perror("VIDIOC_S_FMT");
		return -1;
	}

	return 0;
}

int main(int argc, char **argv)
{
	int camera_index = 0;
	unsigned int width = 1280, height = 720;
	const char *out_path = nullptr;
	int opt;

	static const struct option long_opts[] = {
		{ "camera", required_argument, nullptr, 'c' },
		{ "width", required_argument, nullptr, 'w' },
		{ "height", required_argument, nullptr, 'h' },
		{ "output", required_argument, nullptr, 'o' },
		{ "help", no_argument, nullptr, 'H' },
		{ nullptr, 0, nullptr, 0 },
	};

	while ((opt = getopt_long(argc, argv, "c:w:h:o:H", long_opts, nullptr)) != -1) {
		switch (opt) {
		case 'c':
			camera_index = atoi(optarg);
			break;
		case 'w':
			width = atoi(optarg);
			break;
		case 'h':
			height = atoi(optarg);
			break;
		case 'o':
			out_path = optarg;
			break;
		case 'H':
		default:
			fprintf(stderr,
				"usage: %s [-c camera] [-w width] [-h height] -o /dev/videoN\n",
				argv[0]);
			return opt == 'H' ? 0 : 1;
		}
	}

	if (!out_path) {
		fprintf(stderr, "%s: -o /dev/videoN is required\n", argv[0]);
		return 1;
	}

	CameraManager manager;
	if (manager.start() < 0) {
		fprintf(stderr, "%s: camera manager failed to start\n", argv[0]);
		return 1;
	}

	const std::vector<std::shared_ptr<Camera>> &cameras = manager.cameras();
	if ((size_t)camera_index >= cameras.size()) {
		fprintf(stderr, "%s: camera %d not found (%zu available)\n", argv[0],
			camera_index, cameras.size());
		return 1;
	}

	Feed feed;
	feed.camera = cameras[camera_index];

	if (feed.camera->acquire() < 0) {
		fprintf(stderr, "%s: camera %d is busy\n", argv[0], camera_index);
		return 1;
	}

	feed.out = open(out_path, O_RDWR);
	if (feed.out < 0) {
		perror(out_path);
		return 1;
	}

	std::unique_ptr<CameraConfiguration> config =
		feed.camera->generateConfiguration({ StreamRole::Viewfinder });
	if (!config) {
		fprintf(stderr, "%s: no viewfinder stream\n", argv[0]);
		return 1;
	}

	StreamConfiguration &stream_config = config->at(0);
	stream_config.size = Size(width, height);
	stream_config.pixelFormat = formats::XRGB8888;
	config->validate();

	feed.width = width;
	feed.height = height;

	if (set_out_format(feed) < 0)
		return 1;

	if (feed.camera->configure(config.get()) < 0) {
		fprintf(stderr, "%s: configure failed\n", argv[0]);
		return 1;
	}

	feed.stream = config->at(0).stream();
	feed.width = config->at(0).size.width;
	feed.height = config->at(0).size.height;
	feed.stride = config->at(0).stride ? config->at(0).stride : feed.width * 4;
	feed.yuyv.resize(feed.width * feed.height * 2);

	fprintf(stderr, "%s: camera %d, %ux%u stride %u, %s\n", argv[0],
		camera_index, feed.width, feed.height, feed.stride,
		config->at(0).pixelFormat.toString().c_str());

	FrameBufferAllocator allocator(feed.camera);
	if (allocator.allocate(feed.stream) < 0) {
		fprintf(stderr, "%s: cannot allocate buffers\n", argv[0]);
		return 1;
	}

	std::vector<std::unique_ptr<Request>> requests;
	for (const std::unique_ptr<FrameBuffer> &buffer : allocator.buffers(feed.stream)) {
		std::unique_ptr<Request> request = feed.camera->createRequest();
		if (!request) {
			fprintf(stderr, "%s: cannot create request\n", argv[0]);
			return 1;
		}
		if (request->addBuffer(feed.stream, buffer.get()) < 0) {
			fprintf(stderr, "%s: cannot add buffer\n", argv[0]);
			return 1;
		}
		requests.push_back(std::move(request));
	}

	Handler handler(&feed);
	feed.camera->requestCompleted.connect(&handler, &Handler::requestComplete);

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (feed.camera->start() < 0) {
		fprintf(stderr, "%s: camera failed to start\n", argv[0]);
		return 1;
	}

	for (std::unique_ptr<Request> &request : requests)
		feed.camera->queueRequest(request.get());

	while (!stop)
		pause();

	feed.camera->stop();
	fprintf(stderr, "%s: %u frames\n", argv[0], feed.frames);

	return 0;
}
