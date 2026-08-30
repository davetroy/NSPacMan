// run_full.c — full-loop NSPacMan harness: boots a real .nsi through stage1
// with the faithful FDC model (run_loader.c), then keeps executing the game
// with scripted keyboard injection (run_gf model), and models hardware-correct
// sector WRITES (manual 3.7.7): flag armed after the mark edge targets the
// sector whose counter value is current; stream = zeros, 0xFB, addr byte,
// 512 data, CRC (verified against the MED3C fold).
//
// A second boot pass (fresh RAM) proves what persisted on the "disk".
//
//   cc -O2 -I<dir-with-z80.h> run_full.c -o run_full
//   ./run_full stage1.bin disk.nsi prefix cycles1 keys1 [cycles2 keys2]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "z80.h"
#include "z80.c"

static uint8_t* RAM;
static uint8_t* DISK; static long DISK_LEN;

// ---- floppy state ----------------------------------------------------------
static int trackNum, sectorNum, side;
static bool motorOn, track0;
static int stepDirection; static bool stepPulse, stepPulsePrev;
static int fdcState, fdcStateCounter, fdcStateSectorNum;
static bool sectorMark, serialData, diskReadFlag;
static bool acquireMode, acquireModePrev;
static uint8_t dataBuffer[0x202]; static int bytePtr;
static int ioControlReg;
static const int MAXTRACKS=35;

// ---- write model (hardware-faithful) ---------------------------------------
static bool writeArmed=false; static int wPhase, wIdx, wTarget, wTrack;
static uint8_t wbuf[513]; static int writeCount=0, writeErrs=0;

// ---- keyboard model --------------------------------------------------------
static int kbd_char, kbd_flag, kbd_ack;
static int spk_last; static long spk_toggles;
#define MAXKEYS 24
static unsigned long key_when[MAXKEYS]; static int key_val[MAXKEYS];
static int key_n=0, key_i=0;

static void incrementSectorNum(void){
    sectorNum=(sectorNum+1)%10;
    fdcStateSectorNum=(sectorNum==9)?0x0F:sectorNum;
}
static void floppyStep(void){
    if(stepDirection==0){ if(trackNum>0){ trackNum--; if(trackNum==0) track0=true; } }
    else { trackNum++; if(trackNum>MAXTRACKS) trackNum=MAXTRACKS; track0=false; }
}
static void startSectorRead(void){ incrementSectorNum(); fdcState=100; fdcStateCounter=0; }
static int crc_fold(const uint8_t* p, int n){
    int crc=0;
    for(int i=0;i<n;i++){ int k=p[i]^crc; k+=k; if(k&0x100)k++; crc=k&0xFF; }
    return crc;
}
static void storeSectorBuffer(void){
    int store=(side!=0)?(((MAXTRACKS*2)-1)-trackNum)*10+sectorNum:trackNum*10+sectorNum;
    long off=(long)store*512;
    dataBuffer[0]=0xFB;
    for(int i=0;i<512;i++) dataBuffer[i+1]=(off+i<DISK_LEN)?DISK[off+i]:0;
    dataBuffer[513]=(uint8_t)crc_fold(dataBuffer+1,512);
    bytePtr=0;
}
static void loadDriveControl(uint8_t data){
    if(data&0x01) fdcState=0;
    stepDirection=(data&0x20)?1:0;
    if(data&0x10) stepPulse=true;
    else { stepPulse=false; if(stepPulsePrev) floppyStep(); }
    stepPulsePrev=stepPulse;
    side=(data&0x40)/0x40;
}
static void floppy_state(void){
    switch(fdcState){
    case 0:  fdcState=15; sectorMark=true; break;
    case 15: motorOn=true; sectorMark=true; fdcState=18; fdcStateCounter=60; break;
    case 18: if(--fdcStateCounter==0) fdcState=20; break;
    case 20: incrementSectorNum(); sectorMark=true; fdcState=30; fdcStateCounter=5; break;
    case 30: if(--fdcStateCounter==0) fdcState=35; break;
    case 35: sectorMark=false; fdcState=40; fdcStateCounter=40; break;
    case 40: if(--fdcStateCounter==0) fdcState=15; break;
    case 100: serialData=true; fdcStateCounter=0; break;
    default: fdcState=15; break;
    }
}

static void port_out_cb(z80* z, uint8_t port, uint8_t val){
    uint8_t hi=port>>4, lo=port&0x0F;
    if(hi==0x0A){
        int reg=lo&3;
        if((val&0x80)==0){ int p=val&7; if(val==0)p=reg; z->mapping_regs[reg]=p*0x4000; }
        else if((val&0x84)==0x84) z->mapping_regs[reg]=0x0E*0x4000;
        else if((val&0x06)==0) z->mapping_regs[reg]=(8+(val&1))*0x4000;
    } else if(hi==0x08){
        switch(lo&3){
        case 0:                                   // data OUT: write stream
            if(writeArmed){
                if(wPhase==0){ if(val==0xFB) wPhase=1; }
                else if(wPhase==1){
                    int expect=(wTarget+16*wTrack)&0xFF;
                    if(val!=expect){ fprintf(stderr,"WRITE addr byte %02X != expected %02X\n",val,expect); writeErrs++; }
                    wPhase=2; wIdx=0;
                }
                else if(wIdx<513){
                    wbuf[wIdx++]=val;
                    if(wIdx==513){
                        int crc=crc_fold(wbuf,512);
                        if(wbuf[512]!=(uint8_t)crc){ fprintf(stderr,"WRITE CRC %02X != computed %02X\n",wbuf[512],crc); writeErrs++; }
                        int store=(side!=0)?(((MAXTRACKS*2)-1)-wTrack)*10+wTarget:wTrack*10+wTarget;
                        long off=(long)store*512;
                        if(off+512<=DISK_LEN){ memcpy(DISK+off,wbuf,512); writeCount++;
                            fprintf(stderr,"WRITE OK: track %d sector %d (file 0x%05lX) crc=%02X\n",wTrack,wTarget,off,crc); }
                        else { fprintf(stderr,"WRITE OUT OF RANGE t%d s%d\n",wTrack,wTarget); writeErrs++; }
                        writeArmed=false;
                    }
                }
            }
            break;
        case 1: loadDriveControl(val); break;
        case 2: diskReadFlag=true; motorOn=true; break;
        case 3:                                   // write flag: hardware-faithful —
            // the write targets the sector that begins at this mark.  In the
            // model the mark rises at state 15 but the counter bumps at state
            // 20, so pre-increment states need the +1.
            writeArmed=true; wPhase=0; wIdx=0;
            wTarget=(fdcState==15||fdcState==18)?(sectorNum+1)%10:sectorNum;
            wTrack=trackNum;
            break;
        }
    } else if(port==0xF8){
        int spk=(val&0x40)?1:0;
        if(spk!=spk_last){ spk_toggles++; spk_last=spk; }
        int cmd=val&7; ioControlReg=cmd;
        if(cmd==5) motorOn=true;
        acquireMode=(val&0x08)!=0;
        if(acquireMode && !acquireModePrev) startSectorRead();
        acquireModePrev=acquireMode;
        kbd_ack^=1;
    }
}
static uint8_t port_in_cb(z80* z, uint8_t port){
    (void)z; uint8_t hi=port>>4, lo=port&0x0F;
    if(hi==0x08){
        switch(lo&3){
        case 0: { uint8_t d=(bytePtr<0x202)?dataBuffer[bytePtr]:0xFF;
                  bytePtr++; if(bytePtr>513){ diskReadFlag=false; serialData=false; fdcState=35; }
                  return d; }
        case 1: storeSectorBuffer(); return 0xFB;
        case 2: diskReadFlag=false; return 0xFF;
        default: return 0xFF;
        }
    }
    if(port==0xE0){
        uint8_t s=0x02;
        if(kbd_flag) s|=0x01;
        if(track0) s|=0x20;
        if(sectorMark) s|=0x40;
        if(serialData) s|=0x80;
        return s;                                  // bit4 (WP) = 0: writable
    }
    if(port==0xD0){
        uint8_t s=0;
        if(kbd_flag) s|=0x40;
        if(kbd_ack)  s|=0x80;
        if(ioControlReg==1) s|=(kbd_char&0x0F);
        else if(ioControlReg==2){ s|=((kbd_char>>4)&0x0F); kbd_flag=0; }
        else if(ioControlReg==0||ioControlReg==5) s|=(motorOn?(fdcStateSectorNum&0x0F):0x0E);
        return s;
    }
    return 0xFF;
}

static void parse_keys(const char* spec){
    key_n=0; key_i=0;
    if(!spec||!*spec) return;
    char buf[512]; strncpy(buf,spec,sizeof(buf)-1); buf[sizeof(buf)-1]=0;
    char* tok=strtok(buf,",");
    while(tok&&key_n<MAXKEYS){
        unsigned long w; int c;
        if(sscanf(tok,"%lu:%x",&w,&c)==2){ key_when[key_n]=w; key_val[key_n]=c; key_n++; }
        tok=strtok(NULL,",");
    }
}

static void boot_pass(const uint8_t* stage1, size_t s1len, unsigned long budget,
                      const char* keys, const char* prefix, int pass){
    memset(RAM,0,256*1024);
    memcpy(RAM+0x0C100,stage1,s1len);
    trackNum=0; sectorNum=9; side=0; motorOn=false; track0=true;
    stepDirection=0; stepPulse=stepPulsePrev=false;
    fdcState=0; fdcStateCounter=0; fdcStateSectorNum=0x0F;
    sectorMark=true; serialData=false; diskReadFlag=false;
    acquireMode=acquireModePrev=true; bytePtr=0; ioControlReg=0;
    writeArmed=false; kbd_char=0; kbd_flag=0; kbd_ack=0; spk_last=0; spk_toggles=0;
    parse_keys(keys);

    z80 cpu; z80_init(&cpu);
    cpu.ram=RAM; cpu.use_direct_memory=true;
    cpu.port_in=port_in_cb; cpu.port_out=port_out_cb;
    cpu.mapping_regs[0]=0x00000; cpu.mapping_regs[1]=0x04000;
    cpu.mapping_regs[2]=0x38000; cpu.mapping_regs[3]=0x0C000;
    cpu.pc=0xC10A;

    int pulse=0; bool in_game=false;
    while(cpu.cyc<budget){
        z80_step(&cpu);
        if(++pulse>=34){ pulse=0; floppy_state(); }
        if(!in_game && cpu.pc>=0x8000 && cpu.pc<0xC000){
            in_game=true;
            fprintf(stderr,"[pass %d] stage 2 entered at PC=%04X after %llu cycles\n",pass,cpu.pc,(unsigned long long)cpu.cyc);
        }
        while(key_i<key_n && cpu.cyc>=key_when[key_i]){
            kbd_char=key_val[key_i]; kbd_flag=1; key_i++;
        }
    }
    fprintf(stderr,"[pass %d] done at PC=%04X cyc=%llu speaker toggles=%ld writes=%d errs=%d\n",
            pass,cpu.pc,(unsigned long long)cpu.cyc,spk_toggles,writeCount,writeErrs);
    char path[256];
    snprintf(path,sizeof(path),"%s_fb%d.raw",prefix,pass);
    FILE* o=fopen(path,"wb"); fwrite(RAM+0x20000,1,80*256,o); fclose(o);
    snprintf(path,sizeof(path),"%s_vars%d.raw",prefix,pass);
    o=fopen(path,"wb"); fwrite(RAM+0x0C900,1,0x300,o); fclose(o);
}

int main(int argc,char**argv){
    if(argc<5){ fprintf(stderr,"usage: run_full stage1.bin disk.nsi prefix cycles1 [keys1] [cycles2 [keys2]]\n"); return 2; }
    RAM=malloc(256*1024);
    FILE* f=fopen(argv[2],"rb"); if(!f){perror("disk");return 1;}
    fseek(f,0,SEEK_END); DISK_LEN=ftell(f); fseek(f,0,SEEK_SET);
    DISK=malloc(DISK_LEN); fread(DISK,1,DISK_LEN,f); fclose(f);
    uint8_t stage1[4096]; f=fopen(argv[1],"rb"); if(!f){perror("stage1");return 1;}
    size_t s1len=fread(stage1,1,sizeof(stage1),f); fclose(f);

    boot_pass(stage1,s1len,strtoul(argv[4],0,10),(argc>5)?argv[5]:"",argv[3],1);
    fprintf(stderr,"save sector (file 0x3A00): ");
    for(int i=0;i<16;i++) fprintf(stderr,"%02X ",DISK[0x3A00+i]);
    fprintf(stderr,"\n");
    if(argc>6){
        boot_pass(stage1,s1len,strtoul(argv[6],0,10),(argc>7)?argv[7]:"",argv[3],2);
    }
    return 0;
}
