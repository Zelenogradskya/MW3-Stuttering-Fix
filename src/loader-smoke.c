#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
typedef void * (WINAPI *Create9Fn)(UINT);
typedef ULONG (WINAPI *ReleaseFn)(void*);
int wmain(int argc,wchar_t **argv) {
 if(argc!=2)return 2;HMODULE m=LoadLibraryW(argv[1]);if(!m){printf("LoadLibrary failed: %lu\n",(unsigned long)GetLastError());return 1;}
 Create9Fn f=(Create9Fn)GetProcAddress(m,"Direct3DCreate9");if(!f)return 1;void *obj=f(32);if(!obj)return 1;
 ((ReleaseFn)(*(void***)obj)[2])(obj);FreeLibrary(m);puts("PASS: portable DLL loads and forwards real D3D9.");return 0;
}