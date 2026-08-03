#include <stdio.h>
#include <dlfcn.h>
extern void* objc_getClass(const char*);
int main(int c,char**v){
  setvbuf(stdout,0,_IONBF,0);
  void*h=dlopen(v[1], RTLD_NOW|RTLD_LOCAL);
  if(!h){printf("FAIL: %s\n",dlerror());return 1;}
  printf("dlopen OK\n");
  const char*names[]={"OS_hv_vm_config","OS_hv_vcpu_config","OS_hv_vm_space_config"};
  for(int i=0;i<3;i++){ void*cls=objc_getClass(names[i]); printf("  class %s = %p\n",names[i],cls); }
  void*f=dlsym(h,"hv_vm_create"); printf("hv_vm_create=%p\n",f);
  return 0;
}
