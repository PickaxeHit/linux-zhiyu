/* Match both Boot IDs for normal NixOS boot. SD rescue prefers FHS init
 * and may use any executable NixOS generation.
 * All target-root opens use openat2 so absolute Nix Store symlinks resolve
 * inside the mounted root, not inside the ramdisk. No writes are performed. */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define IDLEN 64
#define PROFILES "/nix/var/nix/profiles"
static int rootfd, profd;
static char kid[IDLEN+1], vid[IDLEN+1];

static int valid_id(const char *s)
{
    if (strlen(s) != IDLEN) return 0;
    for (; *s; ++s) if (!strchr("0123456789abcdef", *s)) return 0;
    return 1;
}
static int set_id(char *dst, const char *src)
{
    if (*dst || !valid_id(src)) return -1;
    memcpy(dst, src, IDLEN+1);
    return 0;
}
static int read_ids(const char *cmdline, const char *bootconfig)
{
    FILE *f = fopen(cmdline, "r");
    char *line = NULL, *save, *t;
    size_t cap = 0;
    int rc = -1;
    if (!f) return -1;
    if (getline(&line, &cap, f) < 0) goto done;
    for (t = strtok_r(line, " \t\r\n", &save); t; t = strtok_r(NULL, " \t\r\n", &save)) {
        const char key[] = "zhiyu.kernel_id=";
        if (!strncmp(t, key, sizeof(key)-1) && set_id(kid, t+sizeof(key)-1)) goto done;
    }
    fclose(f);
    f = fopen(bootconfig, "r");
    if (!f) { free(line); return -1; }
    while (getline(&line, &cap, f) >= 0) {
        const char key[] = "zhiyu.vendor_id";
        char *p = line, *end;
        while (isspace((unsigned char)*p)) ++p;
        if (strncmp(p, key, sizeof(key)-1)) continue;
        p += sizeof(key)-1;
        while (isspace((unsigned char)*p)) ++p;
        if (*p++ != '=') goto done;
        while (isspace((unsigned char)*p)) ++p;
        if (*p++ != '"') goto done;
        end = strchr(p, '"');
        if (!end) goto done;
        *end++ = 0;
        while (isspace((unsigned char)*end)) ++end;
        if (*end || set_id(vid, p)) goto done;
    }
    if (!ferror(f) && *kid && *vid) rc = 0;
done:
    fclose(f);
    free(line);
    return rc;
}
static int rooted_open(const char *path, unsigned long long flags)
{
    struct open_how how = { .flags = flags | O_CLOEXEC,
        .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS };
    return (int)syscall(SYS_openat2, rootfd, path, &how, sizeof(how));
}
static int store_system(const char *path)
{
    const char prefix[] = "/nix/store/";
    const char *p;
    if (strncmp(path, prefix, sizeof(prefix)-1)) return 0;
    p = path + sizeof(prefix)-1;
    if (strlen(p) < 34 || p[32] != '-' || strchr(p, '/')) return 0;
    for (int i=0; i<32; i++) if (!strchr("0123456789abcdfghijklmnpqrsvwxyz", p[i])) return 0;
    return strstr(p+33, "nixos-system-") == p+33;
}
static int simple_name(const char *s)
{
    return *s && strcmp(s,".") && strcmp(s,"..") && !strchr(s,'/');
}
/* Resolve only normal profile chains; final destination must be a Store system. */
static int resolve_profile(const char *name, char out[PATH_MAX])
{
    char link[PATH_MAX], cur[PATH_MAX];
    if (!simple_name(name) || strlen(name)>=sizeof(cur)) return -1;
    strcpy(cur,name);
    for (int depth=0; depth<8; ++depth) {
        ssize_t n=readlinkat(profd,cur,link,sizeof(link)-1);
        if (n<=0 || n>=(ssize_t)sizeof(link)-1) return -1;
        link[n]=0;
        if (store_system(link)) { strcpy(out,link); return 0; }
        if (!strncmp(link,PROFILES "/",sizeof(PROFILES "/")-1))
            memmove(link,link+sizeof(PROFILES "/")-1,strlen(link+sizeof(PROFILES "/")-1)+1);
        if (!simple_name(link)) return -1;
        strcpy(cur,link);
    }
    return -1;
}
static int generation_matches(const char *sys)
{
    char path[PATH_MAX], a[65], b[65], extra;
    struct stat st;
    FILE *f;
    int fd, n, ok;
    n=snprintf(path,sizeof(path),"%s/etc/zhiyu/boot-id",sys);
    if (n<0 || n>=(int)sizeof(path)) return 0;
    fd=rooted_open(path,O_RDONLY|O_NONBLOCK);
    if (fd<0) return 0;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode)) { close(fd); return 0; }
    f=fdopen(fd,"r");
    if (!f) { close(fd); return 0; }
    ok=fscanf(f,"%64s %64s %c",a,b,&extra)==2 && !ferror(f) && !strcmp(a,kid) && !strcmp(b,vid);
    fclose(f);
    return ok;
}

static int executable_init(const char *path)
{
    struct stat st;
    int fd=rooted_open(path,O_PATH);
    if (fd<0) return 0;
    int ok=!fstat(fd,&st) && S_ISREG(st.st_mode) && (st.st_mode & 0111);
    close(fd);
    return ok;
}

static int select_profile(const char *name, char out[PATH_MAX], int rescue)
{
    char sys[PATH_MAX];
    if (resolve_profile(name,sys) || (!rescue && !generation_matches(sys))) return 0;
    int n=snprintf(out,PATH_MAX,"%s/init",sys);
    return n>=0 && n<PATH_MAX && executable_init(out);
}

static unsigned long long generation(const char *name)
{
    const char *p;
    char *end;
    unsigned long long n;
    if (strncmp(name,"system-",7)) return 0;
    p=name+7;
    if (*p<'1' || *p>'9') return 0;
    errno=0;
    n=strtoull(p,&end,10);
    return !errno && !strcmp(end,"-link") ? n : 0;
}
int main(int argc, char **argv)
{
    /* Explicit paths are for tests; boot calls this with the default paths. */
    int rescue=argc>1 && !strcmp(argv[1],"--sd-rescue");
    const char *root="/newroot";
    const char *cmd=argc==4?argv[2]:"/proc/cmdline";
    const char *bc=argc==4?argv[3]:"/proc/bootconfig";
    const char *preferred[]={"system","zhiyu-boot","zhiyu-pending"};
    char selected[PATH_MAX], candidate[PATH_MAX];
    DIR *dir;
    struct dirent *ent;
    unsigned long long best=0;
    if (rescue) {
        if (argc>3) return 2;
        if (argc==3) root=argv[2];
    } else {
        if (argc!=1 && argc!=4) return 2;
        if (argc==4) root=argv[1];
    }
    if (!rescue && read_ids(cmd,bc)) { fprintf(stderr,"zhiyu-boot-select: missing, malformed or duplicate boot IDs\n"); return 1; }
    rootfd=open(root,O_PATH|O_DIRECTORY|O_CLOEXEC);
    if (rootfd<0) { perror(root); return 1; }
    if (rescue && executable_init("/sbin/init")) { puts("/sbin/init"); return 0; }
    profd=rooted_open(PROFILES,O_RDONLY|O_DIRECTORY);
    if (profd<0) { perror(PROFILES); return 1; }
    for (size_t i=0;i<sizeof(preferred)/sizeof(preferred[0]);++i)
        if (select_profile(preferred[i],selected,rescue)) { puts(selected); return 0; }
    dir=fdopendir(dup(profd));
    if (!dir) { perror("fdopendir"); return 1; }
    while ((ent=readdir(dir))) {
        unsigned long long n=generation(ent->d_name);
        if (n>best && select_profile(ent->d_name,candidate,rescue)) { best=n; strcpy(selected,candidate); }
    }
    closedir(dir);
    if (best) { puts(selected); return 0; }
    fprintf(stderr,"zhiyu-boot-select: %s\n", rescue ? "no executable FHS or NixOS rescue init" :
            "no generation matches kernel/vendor IDs; refusing NixOS switch_root");
    return 1;
}
