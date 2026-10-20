static int64_t terrain_live_blocks,terrain_live_bytes;
static void*tracked_alloc(size_t size){if(size>((size_t)-1)-sizeof(uint64_t))return 0;uint64_t*p=alloc_mem(size+sizeof(uint64_t));if(!p)return 0;*p=size;terrain_live_blocks++;terrain_live_bytes+=(int64_t)size;return p+1;}
static void tracked_free(void*ptr){if(!ptr)return;uint64_t*p=(uint64_t*)ptr-1;terrain_live_blocks--;terrain_live_bytes-=(int64_t)*p;free_mem(p);}
/* Transactional resident snapshot. IDs are supplied in lexicographic order;
 * index is identity. No mutable/borrowed GDScript geometry is retained. */
typedef struct { R2 box; int64_t mask; int owner;unsigned char owner_set,set; } Prop;
typedef struct { int x,y;int64_t identity,revision; unsigned char meta_set,set; } Cell;
struct Terrain { Prop *props;Cell *cells;uint32_t *offsets,*ids,*marks,*selected;uint32_t generation,selected_count;int64_t np,nc,epoch;int lowx,lowy,width,height;uint32_t buckets,members;int poisoned; };
static void drop_terrain(Terrain*t){if(!t)return;if(t->props)tracked_free(t->props);if(t->cells)tracked_free(t->cells);if(t->offsets)tracked_free(t->offsets);if(t->ids)tracked_free(t->ids);if(t->marks)tracked_free(t->marks);if(t->selected)tracked_free(t->selected);tracked_free(t);}
static void*zalloc(size_t n){if(!n)return 0;void*p=tracked_alloc(n);if(p)zero_bytes(p,n);return p;}
static int floord(double x){int n=(int)x;return x<n?n-1:n;}
static int validq(V2 p,V2 d,double r){return finite_v(p)&&finite_v(d)&&__builtin_isfinite(r)&&r>=0&&r<=32&&absf32(p.x)<=49152&&absf32(p.y)<=49152&&(double)length(d)<=49152;}
static int inside_box(V2 p,R2 b){V2 e=add(b.p,b.s);return p.x>b.p.x&&p.y>b.p.y&&p.x<e.x&&p.y<e.y;}
static R2 grow(R2 b,double r){float f=(float)r;b.p.x=fsub(b.p.x,f);b.p.y=fsub(b.p.y,f);b.s.x=fadd(b.s.x,fmul(f,2));b.s.y=fadd(b.s.y,fmul(f,2));return b;}
static int intersects(R2 a,R2 b){V2 ae=add(a.p,a.s),be=add(b.p,b.s);return !(a.p.x>be.x||ae.x<b.p.x||a.p.y>be.y||ae.y<b.p.y);}
static int begin_snapshot(Context*c,int64_t np,int64_t nc,int64_t epoch){
 if(np<0||np>65536||nc<0||nc>64||epoch<0||(c->terrain&&epoch<=c->terrain->epoch)){c->admission=1;return 0;}
 Terrain*t=zalloc(sizeof(*t));if(!t){c->admission=2;return 0;}t->np=np;t->nc=nc;t->epoch=epoch;
 t->props=zalloc((size_t)np*sizeof(Prop));t->cells=zalloc((size_t)nc*sizeof(Cell));t->marks=zalloc((size_t)np*sizeof(uint32_t));t->selected=zalloc((size_t)np*sizeof(uint32_t));
 if((np&&(!t->props||!t->marks||!t->selected))||(nc&&!t->cells)){drop_terrain(t);c->admission=2;return 0;}
 drop_terrain(c->pending);c->pending=t;c->admission=0;return 1;
}
static int set_prop(Context*c,int64_t i,R2 b,int64_t mask){Terrain*t=c->pending;V2 end=add(b.p,b.s);
 if(!t||i<0||i>=t->np||!finite_v(b.p)||!finite_v(b.s)||!finite_v(end)||b.s.x<0||b.s.y<0||absf32(b.p.x)>49152||absf32(b.p.y)>49152||absf32(end.x)>49152||absf32(end.y)>49152){if(t)t->poisoned=1;c->admission=1;return 0;}
 t->props[i].box=b;t->props[i].mask=mask;t->props[i].set=1;return 1;
}
static int set_cell(Context*c,int64_t i,V2 v){Terrain*t=c->pending;
 if(!t||i<0||i>=t->nc||!finite_v(v)||absf32(v.x)>64||absf32(v.y)>64||v.x!=(int)v.x||v.y!=(int)v.y){if(t)t->poisoned=1;c->admission=1;return 0;}
 t->cells[i].x=(int)v.x;t->cells[i].y=(int)v.y;t->cells[i].set=1;return 1;
}
static int commit_snapshot(Context*c){Terrain*t=c->pending;if(!t||t->poisoned){c->admission=1;return 0;}
 for(int64_t i=0;i<t->np;i++)if(!t->props[i].set){c->admission=3;return 0;}
 for(int64_t i=0;i<t->nc;i++){if(!t->cells[i].set){c->admission=3;return 0;}for(int64_t j=0;j<i;j++)if(t->cells[i].x==t->cells[j].x&&t->cells[i].y==t->cells[j].y){t->poisoned=1;c->admission=1;return 0;}}
 int lx=384,ly=384,hx=-384,hy=-384;int any=0;
 for(int64_t i=0;i<t->np;i++){Prop*p=&t->props[i];if(!p->mask)continue;V2 e=add(p->box.p,p->box.s);int x=floord((double)p->box.p.x/128),y=floord((double)p->box.p.y/128),ex=floord((double)e.x/128),ey=floord((double)e.y/128);if(x<lx)lx=x;if(y<ly)ly=y;if(ex>hx)hx=ex;if(ey>hy)hy=ey;any=1;}
 t->lowx=lx;t->lowy=ly;t->width=any?hx-lx+1:0;t->height=any?hy-ly+1:0;t->buckets=t->width*t->height;
 if(t->offsets){tracked_free(t->offsets);t->offsets=0;}if(t->ids){tracked_free(t->ids);t->ids=0;}
 t->offsets=zalloc(((size_t)t->buckets+1)*sizeof(uint32_t));if(!t->offsets){c->admission=2;return 0;}
 uint64_t total=0;
 for(int64_t i=0;i<t->np;i++){Prop*p=&t->props[i];if(!p->mask)continue;V2 e=add(p->box.p,p->box.s);for(int y=floord((double)p->box.p.y/128);y<=floord((double)e.y/128);y++)for(int x=floord((double)p->box.p.x/128);x<=floord((double)e.x/128);x++){if(++total>4194304){c->admission=1;t->poisoned=1;return 0;}t->offsets[(y-ly)*t->width+x-lx+1]++;}}
 for(uint32_t i=1;i<=t->buckets;i++)t->offsets[i]+=t->offsets[i-1];t->members=(uint32_t)total;
 t->ids=zalloc((size_t)total*sizeof(uint32_t));uint32_t*cursor=zalloc((size_t)t->buckets*sizeof(uint32_t));if((total&&!t->ids)||(t->buckets&&!cursor)){if(cursor)tracked_free(cursor);c->admission=2;return 0;}
 for(uint32_t i=0;i<t->buckets;i++)cursor[i]=t->offsets[i];
 for(int64_t i=0;i<t->np;i++){Prop*p=&t->props[i];if(!p->mask)continue;V2 e=add(p->box.p,p->box.s);for(int y=floord((double)p->box.p.y/128);y<=floord((double)e.y/128);y++)for(int x=floord((double)p->box.p.x/128);x<=floord((double)e.x/128);x++){uint32_t k=(y-ly)*t->width+x-lx;t->ids[cursor[k]++]=(uint32_t)i;}}
 if(cursor)tracked_free(cursor);drop_terrain(c->terrain);c->terrain=t;c->pending=0;c->admission=0;return 1;
}
static int covered(Context*c,R2 a){Terrain*t=c->terrain;if(!t){c->world_error=1;return 0;}V2 e=add(a.p,a.s);int lx=floord((double)a.p.x/768),ly=floord((double)a.p.y/768),hx=floord(((double)e.x-(a.s.x>0?0.0001:0))/768),hy=floord(((double)e.y-(a.s.y>0?0.0001:0))/768);
 if(hx-lx>8||hy-ly>8){c->world_error=1;return 0;}for(int y=ly;y<=hy;y++)for(int x=lx;x<=hx;x++){int found=0;for(int64_t i=0;i<t->nc;i++)if(t->cells[i].x==x&&t->cells[i].y==y){found=1;break;}if(!found){c->world_error=1;return 0;}}return 1;
}
static void sift(uint32_t*a,uint32_t root,uint32_t n){for(;;){uint32_t child=root*2+1;if(child>=n)return;if(child+1<n&&a[child]<a[child+1])child++;if(a[root]>=a[child])return;uint32_t v=a[root];a[root]=a[child];a[child]=v;root=child;}}
static void sort_ids(uint32_t*a,uint32_t n){if(n<2)return;for(uint32_t i=n/2;i>0;i--)sift(a,i-1,n);for(uint32_t end=n-1;end>0;end--){uint32_t v=a[0];a[0]=a[end];a[end]=v;sift(a,0,end);}}
static void candidates(Context*c,R2 a){Terrain*t=c->terrain;c->queries++;t->selected_count=0;if(++t->generation==0){zero_bytes(t->marks,(size_t)t->np*sizeof(uint32_t));t->generation=1;}if(!t->buckets)return;V2 e=add(a.p,a.s);int lx=floord((double)a.p.x/128),ly=floord((double)a.p.y/128),hx=floord((double)e.x/128),hy=floord((double)e.y/128);if(lx<t->lowx)lx=t->lowx;if(ly<t->lowy)ly=t->lowy;if(hx>=t->lowx+t->width)hx=t->lowx+t->width-1;if(hy>=t->lowy+t->height)hy=t->lowy+t->height-1;
 for(int y=ly;y<=hy;y++)for(int x=lx;x<=hx;x++){uint32_t k=(y-t->lowy)*t->width+x-t->lowx;for(uint32_t j=t->offsets[k];j<t->offsets[k+1];j++){uint32_t i=t->ids[j];if(t->marks[i]!=t->generation){t->marks[i]=t->generation;if(intersects(t->props[i].box,a))t->selected[t->selected_count++]=i;}}}sort_ids(t->selected,t->selected_count);
}
static int walkable(Context*c,V2 p,double r){if(!validq(p,(V2){0,0},r))return 0;R2 a=swept(p,(V2){0,0},r);if(!covered(c,a))return 0;candidates(c,a);Terrain*t=c->terrain;for(uint32_t j=0;j<t->selected_count;j++){uint32_t i=t->selected[j];if(t->props[i].mask&&inside_box(p,grow(t->props[i].box,r)))return 0;}return 1;}
static V2 scale(V2 d,double scalar){float f=(float)scalar;return(V2){fmul(d.x,f),fmul(d.y,f)};}
static V2 terrain_sweep(Context*c,V2 p,V2 d,double r){c->sweep_ok=0;c->hit=-1;c->fraction=0;if(!validq(p,d,r))return p;if(!covered(c,swept(p,d,r)))return p;candidates(c,swept(p,d,r));Terrain*t=c->terrain;double fraction=1;int64_t hit=-1;
 for(uint32_t j=0;j<t->selected_count;j++){uint32_t i=t->selected[j];if(!(t->props[i].mask&3))continue;double f=slab(p,d,grow(t->props[i].box,r));if(f<fraction||(f==fraction&&f<1&&(hit<0||i<hit))){fraction=f;hit=i;}}
 V2 result=add(p,scale(d,fraction));if(!walkable(c,result,r)){result=add(p,scale(d,maximum(0,fraction-0.0002/maximum(length(d),1))));if(!walkable(c,result,r))result=p;}c->sweep_ok=1;c->hit=hit;c->fraction=fraction;return result;
}
static V2 terrain_move(Context*c,V2 p,V2 d,double r){if(!validq(p,d,r)||!covered(c,swept(p,d,r)))return p;V2 point=p;if(d.x!=0)point=terrain_sweep(c,point,(V2){d.x,0},r);if(d.y!=0)point=terrain_sweep(c,point,(V2){0,d.y},r);return point;}
