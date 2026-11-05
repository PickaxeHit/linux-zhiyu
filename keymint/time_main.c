#include <stdio.h>
#include <signal.h>
#include <unistd.h>
int init(void);void deinit(void);
static volatile sig_atomic_t stopping;
static void stop(int s) {(void)s;stopping=1;}
int main(void) {setvbuf(stdout,NULL,_IONBF,0);signal(SIGTERM,stop);signal(SIGINT,stop);int r=init();printf("TIME_LISTENER init=%d\n",r);if(r)return 1;while(!stopping)pause();deinit();return 0;}
