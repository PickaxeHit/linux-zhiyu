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
static int reject_request(void *buf,size_t len) {
 uint32_t h[6]={0};if(len<sizeof h)return -1;memcpy(h,buf,sizeof h);
 printf("REQUEST service=0x2000 cmd=0x%x sectors=%u req_len=%u offset=%u version=%u\n",h[0],h[1],h[2],h[3],h[4]);
 if(h[0]!=0x102||h[2]<512||h[3]>len||h[2]>len-h[3]||!h[1]||h[1]>(len-20)/512)return -1;
 unsigned char req[512];memcpy(req,(char*)buf+h[3],512);unsigned type=((unsigned)req[510]<<8)|req[511];
 printf("RPMB read-only request type=0x%x address=%u blocks=%u\n",type,((unsigned)req[504]<<8)|req[505],((unsigned)req[506]<<8)|req[507]);
 if(type!=2&&type!=4){printf("REJECT non-read request\n");return -1;}
 int fd=open("/dev/bsg/0:0:0:49476",O_RDWR);if(fd<0){perror("open RPMB BSG");return -1;}
 unsigned n=type==2?512:h[1]*512;unsigned char *resp=calloc(1,n);if(!resp){close(fd);return -1;}
 int r=sg_cmd(fd,0xb5,req,sizeof req,0);
 if(r==-11)r=sg_cmd(fd,0xb5,req,sizeof req,0);
 if(!r)r=sg_cmd(fd,0xa2,resp,n,1);
 close(fd);
 uint32_t out[5]={h[0],r?-1:0,r?0:n,20,h[4]};memcpy(buf,out,sizeof out);
 if(!r){memcpy((char*)buf+20,resp,n);printf("RPMB response type=0x%x result=0x%x bytes=%u\n",((unsigned)resp[510]<<8)|resp[511],((unsigned)resp[508]<<8)|resp[509],n);}
 free(resp);return 0;
}
static volatile sig_atomic_t stopped;
static void stop_listener(int sig){(void)sig;stopped=1;}
int main(void) {
 signal(SIGTERM,stop_listener);signal(SIGINT,stop_listener);
 setvbuf(stdout,NULL,_IONBF,0);
 Object root=Object_NULL,env=Object_NULL,reg=Object_NULL,mo=Object_NULL,cbo=Object_NULL;
 void *buf=NULL;size_t len=0;int r;
 r=MinkCom_getRootEnvObject(&root);printf("root=%d\n",r);if(r)return 1;
 r=MinkCom_getClientEnvObject(root,&env);printf("client=%d\n",r);if(r)return 2;
 r=IClientEnv_open(env,CRegisterListenerCBO_UID,&reg);printf("open UID87=%d\n",r);if(r)return 3;
 r=MinkCom_getMemoryObject(root,20040,&mo);printf("memory=%d\n",r);if(r)return 4;
 r=MinkCom_getMemoryObjectInfo(mo,&buf,&len);printf("memory_info=%d size=%zu\n",r,len);if(r)return 5;
 r=CListenerCBO_new(&cbo,0x2000,reject_request,buf,len);printf("cbo=%d\n",r);if(r)return 6;
 r=IRegisterListenerCBO_register(reg,0x2000,cbo,mo);printf("REGISTER RPMB=%d\n",r);if(r)return 7;
 printf("READY read-only RPMB listener (write/program requests rejected)\n");while(!stopped)pause();
 Object_ASSIGN_NULL(reg);Object_ASSIGN_NULL(cbo);Object_ASSIGN_NULL(mo);Object_ASSIGN_NULL(env);Object_ASSIGN_NULL(root);return 0;
}
