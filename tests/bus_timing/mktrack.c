#include <stdio.h>
#include <stdlib.h>
#include "gcr_dsk.h"
int main(void){
  uint8_t sec[4096], nib[6656], back[4096];
  srand(1234);
  for (int i=0;i<4096;i++) sec[i]=rand()&0xff;
  if (gcr_encode_dos_track(sec,0,254,GCR_ORDER_DOS,nib,sizeof nib)!=6656) return 1;
  for (int i=0;i<4096;i++) back[i]=0;
  unsigned m=gcr_decode_dos_track(nib,6656,GCR_ORDER_DOS,back);
  fprintf(stderr,"decode mask %04x\n",m);
  FILE*f=fopen("track0.hex","w"); for(int i=0;i<6656;i++) fprintf(f,"%02x\n",nib[i]); fclose(f);
  return 0;
}
