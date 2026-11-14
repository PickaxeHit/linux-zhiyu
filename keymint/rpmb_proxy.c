#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <linux/bsg.h>
#include <scsi/sg.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include "MinkCom.h"
#include "IClientEnv.h"
#include "IRegisterListenerCBO.h"
#include "CRegisterListenerCBO.h"
#include "CListenerCBO.h"
static int sg_cmd(int fd,unsigned char op,void *data,unsigned size,int input) {
 unsigned char cdb[12]={op,0xec,0,1,0,0,0,0,0,0,0,0},sense[96]={0};
 cdb[6]=size>>24;cdb[7]=size>>16;cdb[8]=size>>8;cdb[9]=size;
 struct sg_io_v4 io={0};io.guard='Q';io.protocol=BSG_PROTOCOL_SCSI;io.subprotocol=BSG_SUB_PROTOCOL_SCSI_CMD;
 io.request_len=sizeof cdb;io.request=(uintptr_t)cdb;io.response=(uintptr_t)sense;io.max_response_len=sizeof sense;io.timeout=3000;
 if(input){io.din_xfer_len=size;io.din_xferp=(uintptr_t)data;}else {io.dout_xfer_len=size;io.dout_xferp=(uintptr_t)data;}
 int r=ioctl(fd,SG_IO,&io);
 printf("BSG op=0x%x rc=%d errno=%d device=%u transport=%u driver=%u sense=%02x/%02x/%02x\n",op,r,r?errno:0,io.device_status,io.transport_status,io.driver_status,sense[2]&15,sense[12],sense[13]);
 if(!r && io.device_status==2 && (sense[2]&15)==6 && sense[12]==0x29)return -11;
 return r||io.device_status||io.transport_status||io.driver_status?-1:0;
}
static int allow_write;
static pthread_mutex_t transaction_lock = PTHREAD_MUTEX_INITIALIZER;

static unsigned frame_type(const unsigned char *frame)
{
 return ((unsigned)frame[510] << 8) | frame[511];
}

static int handle_request(void *buf,size_t len)
{
 enum { READ = 0x102, WRITE = 0x103, FRAME = 512 };
 uint32_t h[6];
 if (len < sizeof h) return -1;
 memcpy(h,buf,sizeof h);
 int writing = h[0] == WRITE;
 if ((h[0] != READ && !writing) || h[3] < sizeof h || h[3] > len ||
     h[2] > len-h[3] || !h[1] || h[1] > (len-20)/FRAME)
  return -1;
 size_t send_len = writing ? (size_t)h[1]*FRAME : FRAME;
 if (h[2] != send_len) return -1;
 unsigned char *request = (unsigned char *)buf+h[3];
 unsigned type = frame_type(request);
 if (writing) {
  printf("RPMB write request frames=%u protocol=0x%x reliable=%u\n",h[1],h[4],h[5]);
  if (!allow_write || h[4] != 0x100 || h[5] != h[1]) return -1;
  for (size_t offset = 0; offset < send_len; offset += FRAME)
   if (frame_type(request+offset) != 3) return -1;
 } else if (type != 2 && type != 4) {
  return -1;
 }

 size_t receive_len = writing || type == 2 ? FRAME : (size_t)h[1]*FRAME;
 unsigned char *response = calloc(1,receive_len);
 if (!response) return -1;
 unsigned char result_request[FRAME] = {[511] = 5};
 pthread_mutex_lock(&transaction_lock);
 int fd = open("/dev/bsg/0:0:0:49476",O_RDWR|O_CLOEXEC);
 int status = -1;
 if (fd >= 0) {
  status = sg_cmd(fd,0xb5,request,send_len,0);
  /* Never retry an authenticated write with an ambiguous outcome. */
  if (!writing && status == -11) status = sg_cmd(fd,0xb5,request,send_len,0);
  if (writing && !status) status = sg_cmd(fd,0xb5,result_request,FRAME,0);
  if (!status) status = sg_cmd(fd,0xa2,response,receive_len,1);
  close(fd);
 }
 pthread_mutex_unlock(&transaction_lock);
 if (writing && !status) {
  unsigned result = ((unsigned)response[508]<<8)|response[509];
  if (frame_type(response)!=0x300 || result!=0) status=-1;
 }
 uint32_t reply[5] = {h[0],status ? (uint32_t)-1 : 0,status ? 0 : receive_len,20,h[4]};
 memcpy(buf,reply,sizeof reply);
 if (!status) {
  memcpy((unsigned char *)buf+sizeof reply,response,receive_len);
  printf("RPMB response type=0x%x result=0x%x bytes=%zu\n",
         frame_type(response),((unsigned)response[508]<<8)|response[509],receive_len);
 }
 free(response);
 return 0;
}

static volatile sig_atomic_t stopped;
static void stop_listener(int sig){(void)sig;stopped=1;}
int main(int argc,char **argv) {
 if (argc == 2 && !strcmp(argv[1],"--allow-write")) allow_write = 1;
 else if (argc != 1) {
  fprintf(stderr,"usage: %s [--allow-write]\n",argv[0]);
  return 2;
 }
 signal(SIGTERM,stop_listener);signal(SIGINT,stop_listener);
 setvbuf(stdout,NULL,_IONBF,0);
 Object root=Object_NULL,env=Object_NULL,reg=Object_NULL,mo=Object_NULL,cbo=Object_NULL;
 void *buf=NULL;size_t len=0;int r;
 r=MinkCom_getRootEnvObject(&root);printf("root=%d\n",r);if(r)return 1;
 r=MinkCom_getClientEnvObject(root,&env);printf("client=%d\n",r);if(r)return 2;
 r=IClientEnv_open(env,CRegisterListenerCBO_UID,&reg);printf("open UID87=%d\n",r);if(r)return 3;
 r=MinkCom_getMemoryObject(root,20040,&mo);printf("memory=%d\n",r);if(r)return 4;
 r=MinkCom_getMemoryObjectInfo(mo,&buf,&len);printf("memory_info=%d size=%zu\n",r,len);if(r)return 5;
 r=CListenerCBO_new(&cbo,0x2000,handle_request,buf,len);printf("cbo=%d\n",r);if(r)return 6;
 r=IRegisterListenerCBO_register(reg,0x2000,cbo,mo);printf("REGISTER RPMB=%d\n",r);if(r)return 7;
 printf("READY RPMB listener (%s)\n",allow_write ? "authenticated writes enabled" : "read-only");while(!stopped)pause();
 Object_ASSIGN_NULL(reg);Object_ASSIGN_NULL(cbo);Object_ASSIGN_NULL(mo);Object_ASSIGN_NULL(env);Object_ASSIGN_NULL(root);return 0;
}
