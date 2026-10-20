#include "gdextension_interface.h"
/* Resident terrain substrate, not yet a gameplay backend. No libc imports. */
typedef struct { float x,y; } V2;
typedef struct { V2 p,s; } R2;
typedef union { int64_t i; double f; GDExtensionBool b; V2 v; R2 r; } Value;
typedef struct { _Alignas(8) unsigned char data[8]; } Name;
typedef struct Terrain Terrain;typedef struct Nav Nav;
typedef struct { R2 *boxes; int64_t count,epoch,status; Terrain *terrain,*pending;Nav *nav;int64_t admission,world_error,queries,sweep_ok,hit;double fraction; } Context;
_Static_assert(sizeof(V2)==8 && sizeof(R2)==16 && sizeof(void*)==8,"pinned float_64 ABI");
#define MAX_BOXES 65536
static GDExtensionClassLibraryPtr lib;
static GDExtensionInterfaceMemAlloc alloc_mem;
static GDExtensionInterfaceMemFree free_mem;
static GDExtensionInterfaceStringNameNewWithUtf8Chars new_name;
static GDExtensionInterfaceClassdbRegisterExtensionClass4 register_class;
static GDExtensionInterfaceClassdbUnregisterExtensionClass unregister_class;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod register_method;
static GDExtensionInterfaceClassdbConstructObject2 construct_object;
static GDExtensionInterfaceObjectSetInstance set_instance;
static GDExtensionInterfaceObjectDestroy destroy_object;
static GDExtensionInterfaceObjectMethodBindPtrcall object_ptrcall;
static GDExtensionInterfaceClassdbGetMethodBind get_method;
static GDExtensionInterfaceVariantGetType get_type;
static GDExtensionInterfaceVariantNewNil new_nil;
static GDExtensionVariantFromTypeConstructorFunc from_type[GDEXTENSION_VARIANT_TYPE_VARIANT_MAX];
static GDExtensionTypeFromVariantConstructorFunc to_type[GDEXTENSION_VARIANT_TYPE_VARIANT_MAX];
static GDExtensionPtrDestructor destroy_name,destroy_string;
static GDExtensionMethodBindPtr notification;
static Name class_name,parent_name,empty_name,empty_string;
static int64_t live_contexts,live_arenas,live_bytes;
static int registered;
static void zero_bytes(void *p,size_t n){volatile unsigned char *b=p;for(size_t i=0;i<n;i++)b[i]=0;}
static int eq(const char*a,const char*b){if(!a||!b)return 0;for(unsigned i=0;i<128;i++){if(a[i]!=b[i])return 0;if(!a[i])return 1;}return 0;}
static float fadd(float a,float b){return (float)(a+b);}
static float fsub(float a,float b){return (float)(a-b);}
static float fmul(float a,float b){return (float)(a*b);}
static V2 add(V2 a,V2 b){return (V2){fadd(a.x,b.x),fadd(a.y,b.y)};}
static V2 sub(V2 a,V2 b){return (V2){fsub(a.x,b.x),fsub(a.y,b.y)};}
static float minf32(float a,float b){return a<b?a:b;}
static float absf32(float a){return __builtin_fabsf(a);}
static float length(V2 a){return __builtin_sqrtf(fadd(fmul(a.x,a.x),fmul(a.y,a.y)));}
static int finite_v(V2 a){return __builtin_isfinite(a.x)&&__builtin_isfinite(a.y);}
static double minimum(double a,double b){return a<b?a:b;}
static double maximum(double a,double b){return a>b?a:b;}
static double slab(V2 p,V2 d,R2 box){
 double enter=-__builtin_inf(),leave=__builtin_inf(); V2 end=add(box.p,box.s);
 const float ps[2]={p.x,p.y},ds[2]={d.x,d.y},lo[2]={box.p.x,box.p.y},hi[2]={end.x,end.y};
 for(int a=0;a<2;a++){
  if(ds[a]==0.0f){if(ps[a]<=lo[a]||ps[a]>=hi[a])return 1.0;}
  else{double first=((double)lo[a]-(double)ps[a])/(double)ds[a];double last=((double)hi[a]-(double)ps[a])/(double)ds[a];enter=maximum(enter,minimum(first,last));leave=minimum(leave,maximum(first,last));}
 }
 return leave>maximum(0.0,enter)&&enter<1.0?minimum(maximum(enter,0.0),1.0):1.0;
}
static R2 swept(V2 p,V2 d,double radius){V2 end=add(p,d);float r=(float)radius;V2 low={minf32(p.x,end.x),minf32(p.y,end.y)};float twice=fmul(r,2.0f);return (R2){{fsub(low.x,r),fsub(low.y,r)},{fadd(absf32(d.x),twice),fadd(absf32(d.y),twice)}};}
static R2 segment(V2 a,V2 b,double radius){V2 d=sub(b,a);float r=(float)radius;float twice=fmul(r,2.0f);return (R2){{fsub(minf32(a.x,b.x),r),fsub(minf32(a.y,b.y),r)},{fadd(absf32(d.x),twice),fadd(absf32(d.y),twice)}};}
#include "terrain.inc"
#include "navigation.inc"
static void release_arena(Context*c){if(c->boxes){free_mem(c->boxes);live_arenas--;live_bytes-=c->count*(int64_t)sizeof(R2);}c->boxes=0;c->count=0;c->epoch=-1;}
static GDExtensionObjectPtr create(void *u,GDExtensionBool post){
 (void)u;Context*c=alloc_mem(sizeof(*c));if(!c)return 0;zero_bytes(c,sizeof(*c));c->epoch=-1;
 GDExtensionObjectPtr o=construct_object(parent_name.data);if(!o){free_mem(c);return 0;}
 set_instance(o,class_name.data,c);live_contexts++;
 if(post){int64_t what=0;GDExtensionBool reversed=0;const GDExtensionConstTypePtr args[]={&what,&reversed};object_ptrcall(notification,o,args,0);}return o;
}
static void free_instance(void*u,GDExtensionClassInstancePtr instance){(void)u;Context*c=instance;if(!c)return;release_arena(c);drop_terrain(c->terrain);drop_terrain(c->pending);drop_nav(c->nav);live_contexts--;free_mem(c);}
enum { RESERVE,PUT,GET,RELEASE,STAT,SLAB,INSIDE,SWEPT,SEGMENT,VALID,LENGTH,DIRECTION,BEGIN_SNAPSHOT,SET_PROP,SET_CELL,COMMIT_SNAPSHOT,TWALK,TSWEEP,TMOVE,TSTAT,TFRACTION,CELL_META,PROP_OWNER,NAV_REQUEST,LOCAL_ROUTE,NAV_STAT,NAV_WAYPOINT,NAV_LENGTH,NAV_CELL,NAV_SEED,GATE_WRAP,NAV_TICK,NAV_DIRECTION,SYNC_ERROR,NAV_FAILURE_POSITION,METHODS };
#define INT GDEXTENSION_VARIANT_TYPE_INT
#define FLOAT GDEXTENSION_VARIANT_TYPE_FLOAT
#define BOOL GDEXTENSION_VARIANT_TYPE_BOOL
#define VECTOR GDEXTENSION_VARIANT_TYPE_VECTOR2
#define RECT GDEXTENSION_VARIANT_TYPE_RECT2
typedef struct {const char*label;int argc;GDExtensionVariantType ret,args[3];Name name,argnames[3];} Method;
static Method methods[METHODS]={
 {"reserve",2,BOOL,{INT,INT}}, {"put_box",2,BOOL,{INT,RECT}}, {"get_box",1,RECT,{INT}},
 {"release_arena",0,BOOL,{0}}, {"stat",1,INT,{INT}}, {"slab_fraction",3,FLOAT,{VECTOR,VECTOR,RECT}},
 {"inside",2,BOOL,{VECTOR,RECT}}, {"swept_rect",3,RECT,{VECTOR,VECTOR,FLOAT}},
 {"segment_rect",3,RECT,{VECTOR,VECTOR,FLOAT}}, {"valid_query",3,BOOL,{VECTOR,VECTOR,FLOAT}},
 {"vector_length",1,FLOAT,{VECTOR}}, {"direction_to",2,VECTOR,{VECTOR,VECTOR}},
 {"begin_snapshot",3,BOOL,{INT,INT,INT}}, {"set_prop",3,BOOL,{INT,RECT,INT}}, {"set_cell",2,BOOL,{INT,VECTOR}}, {"commit_snapshot",0,BOOL,{0}}, {"terrain_walkable",2,BOOL,{VECTOR,FLOAT}}, {"terrain_sweep",3,VECTOR,{VECTOR,VECTOR,FLOAT}}, {"terrain_move",3,VECTOR,{VECTOR,VECTOR,FLOAT}}, {"terrain_stat",1,INT,{INT}}, {"terrain_fraction",0,FLOAT,{0}}, {"set_cell_meta",3,BOOL,{INT,INT,INT}}, {"set_prop_owner",2,BOOL,{INT,INT}}, {"nav_set_request",2,BOOL,{INT,INT}}, {"local_route",3,VECTOR,{VECTOR,VECTOR,FLOAT}}, {"nav_stat",1,INT,{INT}}, {"nav_waypoint",1,VECTOR,{INT}}, {"nav_length",0,FLOAT,{0}}, {"nav_cell_value",2,INT,{INT,INT}}, {"nav_seed",1,INT,{INT}}, {"gate_force_wrap",0,BOOL,{0}}, {"nav_set_tick",1,BOOL,{INT}}, {"nav_direction",3,VECTOR,{VECTOR,VECTOR,FLOAT}}, {"sync_world_error",1,BOOL,{INT}}, {"nav_failure_position",0,VECTOR,{0}}
};
static void evaluate(int id,Context*c,const Value*a,Value*out){
 zero_bytes(out,sizeof(*out));
 switch(id){
 case NAV_FAILURE_POSITION:if(c->nav)out->v=c->nav->query_failure_position;return;
 case SYNC_ERROR:if(a[0].i>=0&&a[0].i<=2){c->world_error=a[0].i;out->b=1;}return;
 case NAV_TICK:out->b=nav_set_tick(c,a[0].i);return;
 case NAV_DIRECTION:out->v=nav_direction(c,a[0].v,a[1].v,a[2].f);return;
 case GATE_WRAP:if(c->terrain){c->terrain->generation=0xffffffffu;out->b=1;}return;
 case CELL_META:out->b=set_meta(c,a[0].i,a[1].i,a[2].i);return;
 case PROP_OWNER:out->b=set_owner(c,a[0].i,a[1].i);return;
 case NAV_REQUEST:out->b=nav_request(c,a[0].i,a[1].i);return;
 case LOCAL_ROUTE:out->v=local_route(c,a[0].v,a[1].v,a[2].f);return;
 case NAV_LENGTH:out->f=c->nav?c->nav->total_length:0;return;
 case NAV_WAYPOINT:if(c->nav&&a[0].i>=0&&a[0].i<c->nav->point_count)out->v=c->nav->points[a[0].i];return;
 case NAV_SEED:out->i=-1;if(c->nav&&c->nav->current&&a[0].i>=0&&a[0].i<c->nav->current->seed_count)out->i=c->nav->current->seeds[a[0].i];return;
 case NAV_CELL:out->i=-1;if(c->nav&&c->nav->current&&a[0].i>=0&&a[0].i<576)out->i=a[1].i==0?c->nav->current->flags[a[0].i]:c->nav->current->distances[a[0].i];return;
 case NAV_STAT:{Nav*n=c->nav;if(!n){out->i=(a[0].i==3||a[0].i==4||a[0].i==5||a[0].i==10)?0:-1;return;}switch(a[0].i){case 0:out->i=n->ok;break;case 1:out->i=n->error;break;case 2:out->i=n->point_count;break;case 3:out->i=n->count;break;case 4:out->i=n->grid_builds;break;case 5:out->i=n->route_builds;break;case 6:out->i=n->query_failure;break;case 7:out->i=n->current?n->current->target:-1;break;case 8:out->i=n->current?n->current->tick:-1;break;case 9:out->i=n->current?n->current->seed_count:0;break;case 10:out->i=n->memo_count;break;case 11:out->i=n->memo_valid?n->memo_tick:-1;break;case 12:out->i=n->query_failure_kind;break;default:out->i=-1;}return;}
 case BEGIN_SNAPSHOT:out->b=begin_snapshot(c,a[0].i,a[1].i,a[2].i);return;
 case SET_PROP:out->b=set_prop(c,a[0].i,a[1].r,a[2].i);return;
 case SET_CELL:out->b=set_cell(c,a[0].i,a[1].v);return;
 case COMMIT_SNAPSHOT:out->b=commit_snapshot(c);return;
 case TWALK:out->b=walkable(c,a[0].v,a[1].f);return;
 case TSWEEP:out->v=terrain_sweep(c,a[0].v,a[1].v,a[2].f);return;
 case TMOVE:out->v=terrain_move(c,a[0].v,a[1].v,a[2].f);return;
 case TFRACTION:out->f=c->fraction;return;
 case TSTAT:switch(a[0].i){case 0:out->i=c->terrain?c->terrain->epoch:-1;break;case 1:out->i=c->terrain!=0;break;case 2:out->i=c->world_error;break;case 3:out->i=c->sweep_ok;break;case 4:out->i=c->hit;break;case 5:out->i=c->queries;break;case 6:out->i=c->admission;break;case 7:out->i=c->terrain?c->terrain->np:0;break;case 8:out->i=c->terrain?c->terrain->nc:0;break;case 10:out->i=terrain_live_blocks;break;case 11:out->i=terrain_live_bytes;break;default:out->i=-1;}return;
 case RESERVE:{int64_t n=a[0].i,epoch=a[1].i;
  if(n<0||n>MAX_BOXES||epoch<0||(uint64_t)n>((size_t)-1)/sizeof(R2)){c->status=1;return;}
  R2*next=n?alloc_mem((size_t)n*sizeof(R2)):0;if(n&&!next){c->status=2;return;}
  if(n)zero_bytes(next,(size_t)n*sizeof(R2));release_arena(c);c->boxes=next;c->count=n;c->epoch=epoch;c->status=0;
  if(n){live_arenas++;live_bytes+=n*(int64_t)sizeof(R2);}out->b=1;return;}
 case PUT:if(a[0].i<0||a[0].i>=c->count||!finite_v(a[1].r.p)||!finite_v(a[1].r.s)||a[1].r.s.x<0||a[1].r.s.y<0){c->status=3;return;}c->boxes[a[0].i]=a[1].r;c->status=0;out->b=1;return;
 case GET:if(a[0].i<0||a[0].i>=c->count){c->status=3;return;}out->r=c->boxes[a[0].i];c->status=0;return;
 case RELEASE:release_arena(c);c->status=0;out->b=1;return;
 case STAT:switch(a[0].i){case 0:out->i=c->count;break;case 1:out->i=c->epoch;break;case 2:out->i=c->status;break;case 3:out->i=live_contexts;break;case 4:out->i=live_arenas;break;case 5:out->i=live_bytes;break;default:out->i=-1;}return;
 case SLAB:out->f=slab(a[0].v,a[1].v,a[2].r);return;
 case INSIDE:{V2 end=add(a[1].r.p,a[1].r.s);out->b=a[0].v.x>a[1].r.p.x&&a[0].v.x<end.x&&a[0].v.y>a[1].r.p.y&&a[0].v.y<end.y;return;}
 case SWEPT:out->r=swept(a[0].v,a[1].v,a[2].f);return;
 case SEGMENT:out->r=segment(a[0].v,a[1].v,a[2].f);return;
 case VALID:out->b=finite_v(a[0].v)&&finite_v(a[1].v)&&__builtin_isfinite(a[2].f)&&a[2].f>=0&&a[2].f<=32&&absf32(a[0].v.x)<=49152&&absf32(a[0].v.y)<=49152&&(double)length(a[1].v)<=49152;return;
 case LENGTH:out->f=length(a[0].v);return;
 case DIRECTION:{V2 d=sub(a[1].v,a[0].v);float n=length(d);out->v=n==0?(V2){0,0}:(V2){(float)(d.x/n),(float)(d.y/n)};return;}
 }
}
static void*slot(Value*v,GDExtensionVariantType t){switch(t){case INT:return &v->i;case FLOAT:return &v->f;case BOOL:return &v->b;case VECTOR:return &v->v;default:return &v->r;}}
static void method_call(void*ud,GDExtensionClassInstancePtr c,const GDExtensionConstVariantPtr*args,GDExtensionInt n,GDExtensionVariantPtr ret,GDExtensionCallError*error){
 Method*m=ud;error->error=GDEXTENSION_CALL_OK;error->argument=0;error->expected=0;
 if(n!=m->argc){error->error=n<m->argc?GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS:GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS;error->expected=m->argc;new_nil(ret);return;}
 Value a[3],result;zero_bytes(a,sizeof(a));
 for(int i=0;i<m->argc;i++){if(get_type(args[i])!=m->args[i]){error->error=GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;error->argument=i;error->expected=m->args[i];new_nil(ret);return;}to_type[m->args[i]](slot(&a[i],m->args[i]),(GDExtensionVariantPtr)args[i]);}
 evaluate((int)(m-methods),c,a,&result);from_type[m->ret](ret,slot(&result,m->ret));
}
static void method_ptrcall(void*ud,GDExtensionClassInstancePtr c,const GDExtensionConstTypePtr*args,GDExtensionTypePtr ret){
 Method*m=ud;Value a[3],result;zero_bytes(a,sizeof(a));
 for(int i=0;i<m->argc;i++){switch(m->args[i]){case INT:a[i].i=*(const int64_t*)args[i];break;case FLOAT:a[i].f=*(const double*)args[i];break;case VECTOR:a[i].v=*(const V2*)args[i];break;case RECT:a[i].r=*(const R2*)args[i];break;default:break;}}
 evaluate((int)(m-methods),c,a,&result);
 switch(m->ret){case INT:*(int64_t*)ret=result.i;break;case FLOAT:*(double*)ret=result.f;break;case BOOL:*(GDExtensionBool*)ret=result.b;break;case VECTOR:*(V2*)ret=result.v;break;case RECT:*(R2*)ret=result.r;break;default:break;}
}
static void initialize(void*u,GDExtensionInitializationLevel level){
 (void)u;if(level!=GDEXTENSION_INITIALIZATION_SCENE)return;
 GDExtensionClassCreationInfo4 info;zero_bytes(&info,sizeof(info));info.is_exposed=1;info.create_instance_func=create;info.free_instance_func=free_instance;
 register_class(lib,class_name.data,parent_name.data,&info);registered=1;
 for(int k=0;k<METHODS;k++){
  Method*m=&methods[k];new_name(m->name.data,m->label);
  GDExtensionPropertyInfo return_info,args[3];GDExtensionClassMethodArgumentMetadata metas[3];GDExtensionClassMethodInfo mi;
  zero_bytes(&return_info,sizeof(return_info));zero_bytes(args,sizeof(args));zero_bytes(metas,sizeof(metas));zero_bytes(&mi,sizeof(mi));
  return_info.type=m->ret;return_info.name=empty_name.data;return_info.class_name=empty_name.data;return_info.hint_string=empty_string.data;return_info.usage=6;
  for(int i=0;i<m->argc;i++){const char*names[]={"a","b","c"};new_name(m->argnames[i].data,names[i]);args[i].type=m->args[i];args[i].name=m->argnames[i].data;args[i].class_name=empty_name.data;args[i].hint_string=empty_string.data;args[i].usage=6;}
  mi.name=m->name.data;mi.method_userdata=m;mi.call_func=method_call;mi.ptrcall_func=method_ptrcall;mi.method_flags=GDEXTENSION_METHOD_FLAG_NORMAL;mi.has_return_value=1;mi.return_value_info=&return_info;mi.argument_count=m->argc;mi.arguments_info=args;mi.arguments_metadata=metas;
  register_method(lib,class_name.data,&mi);
 }
}
static void deinitialize(void*u,GDExtensionInitializationLevel level){
 (void)u;if(level!=GDEXTENSION_INITIALIZATION_SCENE||!registered)return;
 unregister_class(lib,class_name.data);registered=0;
 for(int k=0;k<METHODS;k++){destroy_name(methods[k].name.data);for(int i=0;i<methods[k].argc;i++)destroy_name(methods[k].argnames[i].data);}
 destroy_name(class_name.data);destroy_name(parent_name.data);destroy_name(empty_name.data);destroy_string(empty_string.data);
}
#define LOAD(var,type,name) var=(type)(void*)get_proc(name);if(!var)return 0
__attribute__((visibility("default")))
GDExtensionBool wings_resident_init(GDExtensionInterfaceGetProcAddress get_proc,GDExtensionClassLibraryPtr library,GDExtensionInitialization*init){
 if(!get_proc||!init)return 0;lib=library;
 GDExtensionInterfaceGetGodotVersion2 version_fn;LOAD(version_fn,GDExtensionInterfaceGetGodotVersion2,"get_godot_version2");GDExtensionGodotVersion2 v;version_fn(&v);
 if(v.major!=4||v.minor!=6||v.patch!=3||!eq(v.status,"stable")||!eq(v.build,"official")||!eq(v.hash,"7d41c59c457bd5a245092b4e7eb2d833e3b3f8c3"))return 0;
 LOAD(alloc_mem,GDExtensionInterfaceMemAlloc,"mem_alloc");LOAD(free_mem,GDExtensionInterfaceMemFree,"mem_free");
 LOAD(new_name,GDExtensionInterfaceStringNameNewWithUtf8Chars,"string_name_new_with_utf8_chars");
 LOAD(register_class,GDExtensionInterfaceClassdbRegisterExtensionClass4,"classdb_register_extension_class4");LOAD(unregister_class,GDExtensionInterfaceClassdbUnregisterExtensionClass,"classdb_unregister_extension_class");
 LOAD(register_method,GDExtensionInterfaceClassdbRegisterExtensionClassMethod,"classdb_register_extension_class_method");LOAD(construct_object,GDExtensionInterfaceClassdbConstructObject2,"classdb_construct_object2");
 LOAD(set_instance,GDExtensionInterfaceObjectSetInstance,"object_set_instance");LOAD(destroy_object,GDExtensionInterfaceObjectDestroy,"object_destroy");
 LOAD(get_method,GDExtensionInterfaceClassdbGetMethodBind,"classdb_get_method_bind");LOAD(object_ptrcall,GDExtensionInterfaceObjectMethodBindPtrcall,"object_method_bind_ptrcall");
 LOAD(get_type,GDExtensionInterfaceVariantGetType,"variant_get_type");LOAD(new_nil,GDExtensionInterfaceVariantNewNil,"variant_new_nil");
 GDExtensionInterfaceGetVariantFromTypeConstructor get_from;GDExtensionInterfaceGetVariantToTypeConstructor get_to;GDExtensionInterfaceVariantGetPtrDestructor get_destroy;GDExtensionInterfaceVariantGetPtrConstructor get_construct;
 LOAD(get_from,GDExtensionInterfaceGetVariantFromTypeConstructor,"get_variant_from_type_constructor");LOAD(get_to,GDExtensionInterfaceGetVariantToTypeConstructor,"get_variant_to_type_constructor");
 LOAD(get_destroy,GDExtensionInterfaceVariantGetPtrDestructor,"variant_get_ptr_destructor");LOAD(get_construct,GDExtensionInterfaceVariantGetPtrConstructor,"variant_get_ptr_constructor");
 const GDExtensionVariantType types[]={INT,FLOAT,BOOL,VECTOR,RECT};for(int i=0;i<5;i++){from_type[types[i]]=get_from(types[i]);to_type[types[i]]=get_to(types[i]);if(!from_type[types[i]]||!to_type[types[i]])return 0;}
 destroy_name=get_destroy(GDEXTENSION_VARIANT_TYPE_STRING_NAME);destroy_string=get_destroy(GDEXTENSION_VARIANT_TYPE_STRING);GDExtensionPtrConstructor new_string=get_construct(GDEXTENSION_VARIANT_TYPE_STRING,0);if(!destroy_name||!destroy_string||!new_string)return 0;
 new_name(class_name.data,"WingsResidentContext");new_name(parent_name.data,"RefCounted");new_name(empty_name.data,"");new_string(empty_string.data,0);
 Name object,notify;new_name(object.data,"Object");new_name(notify.data,"notification");notification=get_method(object.data,notify.data,4023243586LL);destroy_name(object.data);destroy_name(notify.data);
 if(!notification){destroy_name(class_name.data);destroy_name(parent_name.data);destroy_name(empty_name.data);destroy_string(empty_string.data);return 0;}
 init->minimum_initialization_level=GDEXTENSION_INITIALIZATION_SCENE;init->userdata=0;init->initialize=initialize;init->deinitialize=deinitialize;return 1;
}
