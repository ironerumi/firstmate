import ctypes, mmap, os, struct, subprocess, sys, time
m=mmap.mmap(-1,256*1024*1024)
m[:]=b'x'*(256*1024*1024)
address=ctypes.addressof(ctypes.c_char.from_buffer(m))
lib=ctypes.CDLL(None,use_errno=True)
lib.madvise.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]
rc=lib.madvise(address,len(m),10) # SDK sys/mman.h MADV_PAGEOUT, owned mapping only
print('MADV_PAGEOUT rc=%d errno=%d'%(rc,ctypes.get_errno()),flush=True)
p=ctypes.CDLL('/usr/lib/libproc.dylib')
for i in range(10):
 b=ctypes.create_string_buffer(232)
 r=p.proc_pid_rusage(os.getpid(),0,ctypes.byref(b))
 f=struct.unpack_from('Q',b,72)[0]//1024 if r==0 else -1
 rss=int(subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True))
 print('pid=%d footprint_KiB=%d rss_KiB=%d'%(os.getpid(),f,rss),flush=True)
 if rc!=0: break
 time.sleep(.1)
if '--hold' in sys.argv: time.sleep(30)
