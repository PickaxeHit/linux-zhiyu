/* Recover this device's existing Android metadata key through mainline QCOMTEE.
 * No key provisioning, deletion, metadata writes, or RPMB writes.
 * Protocol derived from the successful TB378FC vendor HAL capture.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <openssl/sha.h>
#include "MinkCom.h"

/* Minimal object protocol: open UID, resolve app name, send byte buffers. */
static int open_uid(Object self, uint32_t uid, Object *out)
{
 ObjectArg args[]={{.b={&uid,sizeof uid}},{.o=Object_NULL}};
 int r=Object_invoke(self,0,args,ObjectCounts_pack(1,0,0,1));
 *out=args[1].o;return r;
}
static int resolve_app(Object self, const void *name, size_t len, Object *out)
{
 ObjectArg args[]={{.bi={name,len}},{.o=Object_NULL}};
 int r=Object_invoke(self,0,args,ObjectCounts_pack(1,0,0,1));
 *out=args[1].o;return r;
}
static int send_hal(Object self,const void *in,size_t len,void *out,size_t cap,size_t *actual)
{
 ObjectArg args[]={{.bi={in,len}},{.b={out,cap}}};
 int r=Object_invoke(self,0,args,ObjectCounts_pack(1,1,0,0));
 *actual=args[1].b.size;return r;
}

static uint8_t request[16384], response[16384];
static size_t used;
static Object root, env, app, appobj, km;
static uint64_t operation;
static void fail(const char *s) { fprintf(stderr,"ERROR: %s\n",s); exit(1); }
static void put(uint8_t b) { if(used>=sizeof request)fail("request too large");request[used++]=b; }
static void bytes(const void *p,size_t n) {if(n>sizeof request-used)fail("request too large");memcpy(request+used,p,n);used+=n;}
static void head(unsigned major,uint64_t n) {
 if(n<24){put((major<<5)|n);return;}
 unsigned width=n<=0xff?1:n<=0xffff?2:n<=0xffffffffULL?4:8;
 put((major<<5)|(width==1?24:width==2?25:width==4?26:27));
 for(unsigned i=width;i;i--)put(n>>(8*(i-1)));
}
static void u(uint64_t n) {head(0,n);}
static void tag(uint32_t n) {if((int32_t)n<0)head(1,~n);else head(0,n);}
static void bstr(const void *p,size_t n) {head(2,n);bytes(p,n);}
static void begin_msg(uint32_t op) {used=0;bytes(&op,4);}
static size_t read_file(const char *dir,const char *name,uint8_t *buf,size_t cap) {
 char path[1024];if(snprintf(path,sizeof path,"%s/%s",dir,name)>=(int)sizeof path)fail("path too long");
 FILE *f=fopen(path,"rb");if(!f){perror(path);exit(1);}size_t n=fread(buf,1,cap,f);
 if(ferror(f)||fgetc(f)!=EOF){fclose(f);fail("file exceeds supported size or cannot be read");}fclose(f);return n;
}
/* Strict bounded CBOR reader. Only unsigned map keys and byte strings are used
 * by the responses needed here. Recursion also skips unrelated array/map values.
 */
struct item {unsigned major;uint64_t value;const uint8_t *data;size_t size;};
static int next(const uint8_t **p,const uint8_t *end,struct item *v,unsigned depth) {
 if(depth>16||*p>=end)return -1;
 uint8_t h=*(*p)++;unsigned a=h&31;v->major=h>>5;v->value=a;v->data=NULL;v->size=0;
 if(a>=24){unsigned w=a==24?1:a==25?2:a==26?4:a==27?8:0;if(!w||(size_t)(end-*p)<w)return -1;v->value=0;while(w--)v->value=(v->value<<8)|*(*p)++;}
 if(v->major==2||v->major==3){if(v->value>(uint64_t)(end-*p))return -1;v->data=*p;v->size=v->value;*p+=v->size;}
 else if(v->major==4||v->major==5){uint64_t count=v->value;if(v->major==5){if(count>UINT64_MAX/2)return -1;count*=2;}if(count>(uint64_t)(end-*p))return -1;struct item child;while(count--)if(next(p,end,&child,depth+1))return -1;}
 else if(v->major==6){struct item child;if(next(p,end,&child,depth+1))return -1;}
 return 0;
}
static uint64_t get_handle(const uint8_t *p,size_t n) {
 const uint8_t *end=p+n;if(p==end||(*p>>5)!=5)return 0;
 unsigned count=*p++&31;if(count>=24)return 0;
 while(count--){struct item key,val;if(next(&p,end,&key,0)||next(&p,end,&val,0))return 0;if(key.major==0&&key.value==34&&val.major==0)return val.value;}
 return 0;
}
static int scan_bstr(const uint8_t **p,const uint8_t *end,const uint8_t **best,size_t *size,unsigned depth) {
 if(depth>16||*p>=end)return -1;
 const uint8_t *start=*p;uint8_t h=*(*p)++;unsigned major=h>>5,a=h&31;uint64_t n=a;
 if(a>=24){unsigned w=a==24?1:a==25?2:a==26?4:a==27?8:0;if(!w||(size_t)(end-*p)<w)return -1;n=0;while(w--)n=(n<<8)|*(*p)++;}
 if(major==2||major==3){if(n>(uint64_t)(end-*p))return -1;if(major==2&&n>*size){*best=*p;*size=n;}*p+=n;return 0;}
 if(major==4||major==5||major==6){uint64_t count=major==6?1:n;if(major==5){if(count>UINT64_MAX/2)return -1;count*=2;}if(count>(uint64_t)(end-*p))return -1;while(count--)if(scan_bstr(p,end,best,size,depth+1))return -1;return 0;}
 (void)start;return 0;
}
static size_t extract_blob(const uint8_t *p,size_t n,uint8_t *out,size_t cap) {
 const uint8_t *end=p+n,*best=NULL;size_t size=0;
 if(scan_bstr(&p,end,&best,&size,0)||p!=end||!best||size>cap)fail("unexpected CBOR blob response");
 memcpy(out,best,size);return size;
}
static int send(const char *name,size_t *n) {
 size_t actual=0;memset(response,0,sizeof response);
 int r=send_hal(km,request,used,response,sizeof response,&actual);
 if(r){fprintf(stderr,"%s object_error=%d\n",name,r);return r;}
 if(actual<8||actual>sizeof response)fail("invalid transport response length");
 int32_t status;uint32_t length;memcpy(&status,response,4);memcpy(&length,response+4,4);
 printf("%s status=%d\n",name,status);
 if(status)return status;
 if(length>actual-8)fail("invalid response payload length");
 *n=length;return 0;
}
static void check(int r,const char *what) {if(r){fprintf(stderr,"%s failed (%d)\n",what,r);exit(1);}}
int main(int argc,char **argv) {
 if(argc!=3){fprintf(stderr,"usage: %s KEY_DIRECTORY OUTPUT_EPHEMERAL_KEY\n",argv[0]);return 2;}
 setvbuf(stdout,NULL,_IONBF,0);umask(077);
 uint8_t kek[8192],enc[8192],sec[65536],appid[64],lt[4096],ephemeral[256];
 size_t kn=read_file(argv[1],"keymaster_key_blob",kek,sizeof kek);
 size_t en=read_file(argv[1],"encrypted_key",enc,sizeof enc);
 size_t sn=read_file(argv[1],"secdiscardable",sec,sizeof sec);
 if(!kn||en<28||sn!=16384)fail("unexpected metadata key files");
 uint8_t *hash_input=calloc(1,128+sn);if(!hash_input)fail("out of memory");
 memcpy(hash_input,"Android secdiscardable SHA512",sizeof("Android secdiscardable SHA512")-1);memcpy(hash_input+128,sec,sn);
 SHA512_CTX sha;
 if(!SHA512_Init(&sha)||!SHA512_Update(&sha,hash_input,128+sn)||!SHA512_Final(appid,&sha))
  fail("SHA512 failed");
 free(hash_input);
 check(MinkCom_getRootEnvObject(&root),"QCOMTEE root");
 check(MinkCom_getClientEnvObject(root,&env),"QCOMTEE client env");
 check(open_uid(env,151,&app),"open app client");
 check(resolve_app(app,"keymaster64",11,&appobj),"open KeyMint app");
 check(open_uid(appobj,150,&km),"open KeyMint HAL");
 size_t n;
 begin_msg(0x3121);head(5,1);u(11);u(300);check(send("SET_VERSION",&n),"SET_VERSION");
 begin_msg(0x2116);head(5,5);u(22);u(4);tag(0x300002c1);u(170000);tag(0x300002c2);u(20260901);tag(0x300002ce);u(20250605);tag(0x30003a99);u(0);check(send("CONFIGURE",&n),"CONFIGURE");
 begin_msg(0x310f);head(5,8);u(22);u(6);tag(0x20000004);u(32);tag(0x20000006);u(1);tag(0x300003eb);u(128);tag(0x90000259);bstr(appid,64);tag(0x900003e9);bstr(enc,12);tag(0x20000001);u(1);u(23);bstr(kek,kn);
 check(send("BEGIN",&n),"BEGIN");operation=get_handle(response+8,n);if(!operation)fail("missing operation handle");
 begin_msg(0x3111);head(5,2);u(34);u(operation);u(35);bstr(enc+12,en-12);check(send("UNWRAP_3111",&n),"UNWRAP_3111");
 size_t ln=extract_blob(response+8,n,lt,sizeof lt);printf("LT_BYTES=%zu\n",ln);if(ln!=250)fail("unexpected LT blob size");
 begin_msg(0x311d);head(5,1);u(23);bstr(lt,ln);check(send("CONVERT",&n),"CONVERT");
 size_t epn=extract_blob(response+8,n,ephemeral,sizeof ephemeral);if(epn!=100)fail("unexpected ephemeral key size");
 int fd=open(argv[2],O_CREAT|O_EXCL|O_NOFOLLOW|O_WRONLY,0600);if(fd<0){perror(argv[2]);return 1;}
 ssize_t written=write(fd,ephemeral,epn);if(written!=(ssize_t)epn||fsync(fd)){close(fd);unlink(argv[2]);fail("cannot save ephemeral key");}close(fd);
 explicit_bzero(ephemeral,sizeof ephemeral);explicit_bzero(lt,sizeof lt);explicit_bzero(appid,sizeof appid);explicit_bzero(response,sizeof response);
 printf("EPHEMERAL_BYTES=%zu\n",epn);
 Object_release(km);Object_release(appobj);Object_release(app);Object_release(env);Object_release(root);
 return 0;
}
