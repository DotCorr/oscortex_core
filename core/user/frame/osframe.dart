// core/user/frame/osframe.dart — DCDart sibling of osframe.h.
//
// The same allocated numbers, as integer literals a @bare program can
// name. Not compiled into the kernel. Not a new syscall. FRAME1.

const int osframeMagic = 0x46524D31;
const int osframeVersion = 1;

const int osframeSysExit = 0;
const int osframeSysWrite = 1;
const int osframeSysYield = 3;
const int osframeSysSbrk = 4;
const int osframeSysOpen = 5;
const int osframeSysRead = 6;
const int osframeSysClose = 7;
const int osframeSysSeek = 8;
const int osframeSysFdwrite = 9;
const int osframeSysShmcreate = 16;
const int osframeSysShmgrant = 17;
const int osframeSysShmmap = 18;
const int osframeSysShmdrop = 19;
const int osframeSysMouse = 20;
const int osframeSysWmsurface = 23;
const int osframeSysKbdevent = 24;
const int osframeSysWmevent = 25;
const int osframeSysSpawn = 26;
