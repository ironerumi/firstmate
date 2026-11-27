
import ctypes, os, subprocess, sys, time
b = bytearray(256*1024*1024)
for i in range(0,len(b),4096): b[i] = 97
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
buf = ctypes.create_string_buffer(232)
rc = lib.proc_pid_rusage(os.getpid(), 0, ctypes.byref(buf))
import struct
footprint = struct.unpack_from('Q',buf,72)[0]//1024 if rc == 0 else -1
rss = subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())],text=True).strip()
print('allocation_pid=%d populated_MiB=256 independent_proc_pid_rusage_footprint_KiB=%d ps_rss_KiB=%s' % (os.getpid(),footprint,rss),flush=True)
time.sleep(float(sys.argv[1]))
