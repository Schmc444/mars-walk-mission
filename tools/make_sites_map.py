"""Writes docs/sites.html: a self-contained map + table of the HiRISE DTM sites in data/hirise_dtm_index.json."""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sites = [dict(id=e["id"], w=e["lon_w"], e=e["lon_e"], s=e["lat_s"], n=e["lat_n"], a=e["area_km2"], px=e["px_m"])
         for e in json.load(open(os.path.join(root, "data", "hirise_dtm_index.json")))["sites"] if "lon_w" in e]
html = r"""<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sitios HiRISE</title>
<style>
body{margin:0;font:14px system-ui,sans-serif;background:#14100e;color:#e8dcd2}
header{padding:12px 16px}h1{font-size:18px;margin:0 0 4px}
#wrap{display:flex;flex-wrap:wrap;gap:12px;padding:0 16px 16px}
canvas{background:#221a16;border:1px solid #4a3a30;max-width:100%;cursor:crosshair}
#side{flex:1;min-width:320px}
input{width:100%;padding:6px;background:#221a16;color:inherit;border:1px solid #4a3a30;box-sizing:border-box}
#tbl{max-height:520px;overflow:auto;margin-top:8px;border:1px solid #4a3a30}
table{border-collapse:collapse;width:100%}th,td{padding:3px 6px;text-align:left;white-space:nowrap}
tr:hover,tr.sel{background:#4a2e22}th{position:sticky;top:0;background:#2e211a;cursor:pointer}
#info{min-height:3.2em;padding:6px 0;font-family:monospace}
</style>
<header><h1>Sitios con modelo de elevación HiRISE (~1 m/px)</h1>
<div id=cnt></div><div>Pasa el mouse o haz clic en el mapa; la tabla se ordena por columna. Rojo = seleccionado, naranja = coincide con el filtro.</div></header>
<div id=wrap><div><canvas id=c width=1000 height=520></canvas><div id=info></div></div>
<div id=side><input id=q placeholder="filtrar por id (ej. ESP_0459) o 'lon,lat' (ej. 77.4,18.4)"><div id=tbl><table id=t></table></div></div></div>
<script>
const S=__DATA__;const LAND=[["Jezero",77.5,18.4],["Gale",137.4,-5.4],["Olympus Mons",-133.8,18.65]];
const c=document.getElementById('c'),g=c.getContext('2d');let sel=null,flt=null,sortk='a',sortd=-1;
const X=l=>(l+180)/360*c.width,Y=la=>(90-la)/180*c.height;
function draw(){g.clearRect(0,0,c.width,c.height);g.strokeStyle='#3a2c24';g.lineWidth=1;g.fillStyle='#8a7466';g.font='10px sans-serif';
for(let l=-180;l<=180;l+=30){g.beginPath();g.moveTo(X(l),0);g.lineTo(X(l),c.height);g.stroke();g.fillText(l,X(l)+2,c.height-2)}
for(let a=-90;a<=90;a+=30){g.beginPath();g.moveTo(0,Y(a));g.lineTo(c.width,Y(a));g.stroke();g.fillText(a,2,Y(a)-2)}
for(const s of S){const hit=flt&&flt.has(s.id);g.fillStyle=hit?'#ffa040':'rgba(230,140,90,.55)';
g.fillRect(X(s.w),Y(s.n),Math.max(2,X(s.e)-X(s.w)),Math.max(2,Y(s.s)-Y(s.n)))}
g.fillStyle='#8cf';g.font='11px sans-serif';for(const[n,l,a]of LAND){g.fillRect(X(l)-2,Y(a)-2,4,4);g.fillText(n,X(l)+5,Y(a)-4)}
if(sel){g.strokeStyle='#f33';g.lineWidth=2;g.strokeRect(X(sel.w)-3,Y(sel.n)-3,Math.max(8,X(sel.e)-X(sel.w))+6,Math.max(8,Y(sel.s)-Y(sel.n))+6)}}
function at(ev){const r=c.getBoundingClientRect(),lon=(ev.clientX-r.left)/r.width*360-180,lat=90-(ev.clientY-r.top)/r.height*180;
return S.filter(s=>lon>=s.w&&lon<=s.e&&lat>=s.s&&lat<=s.n).sort((a,b)=>a.a-b.a)[0]}
function show(s){sel=s;const m=document.getElementById('info');if(!s){m.textContent='';draw();return}
const cl=((s.w+s.e)/2).toFixed(4),ca=((s.s+s.n)/2).toFixed(4);
m.textContent=s.id+'\n'+s.a+' km2, '+s.px+' m/px  centro lon '+cl+' lat '+ca;m.style.whiteSpace='pre';draw();
document.querySelectorAll('tr.sel').forEach(r=>r.classList.remove('sel'));const r=document.getElementById('r_'+s.id);if(r){r.classList.add('sel');r.scrollIntoView({block:'nearest'})}}
c.onmousemove=e=>{if(!sel||sel._h){const s=at(e);document.getElementById('info').textContent=s?s.id+'  '+s.a+' km2':''}};
c.onclick=e=>{const s=at(e);if(s){s._h=0;show(s)}};
function table(){const rows=[...S].sort((a,b)=>(a[sortk]>b[sortk]?1:-1)*sortd);
document.getElementById('t').innerHTML='<tr><th data-k=id>id<th data-k=a>km2<th data-k=px>m/px<th data-k=w>lon<th data-k=s>lat</tr>'+
rows.map(s=>'<tr id=r_'+s.id+' data-id='+s.id+(flt&&flt.has(s.id)?' style="color:#ffa040"':'')+'><td>'+s.id+'<td>'+s.a+'<td>'+s.px+'<td>'+((s.w+s.e)/2).toFixed(2)+'<td>'+((s.s+s.n)/2).toFixed(2)).join('');
document.querySelectorAll('th').forEach(h=>h.onclick=()=>{const k=h.dataset.k;sortd=k==sortk?-sortd:1;sortk=k;table()});
document.querySelectorAll('tr[data-id]').forEach(r=>r.onclick=()=>show(S.find(s=>s.id==r.dataset.id)))}
document.getElementById('q').oninput=e=>{const v=e.target.value.trim();flt=null;
if(/^-?[\d.]+\s*,\s*-?[\d.]+$/.test(v)){const[lo,la]=v.split(',').map(Number);flt=new Set(S.filter(s=>lo>=s.w&&lo<=s.e&&la>=s.s&&la<=s.n).map(s=>s.id))}
else if(v)flt=new Set(S.filter(s=>s.id.toLowerCase().includes(v.toLowerCase())).map(s=>s.id));
document.getElementById('cnt').textContent=S.length+' sitios'+(flt?' - '+flt.size+' coinciden':'');table();draw()};
document.getElementById('cnt').textContent=S.length+' sitios';table();draw();
</script></html>"""
open(os.path.join(root, "docs", "sites.html"), "w").write(html.replace("__DATA__", json.dumps(sites, separators=(",", ":"))))
print("docs/sites.html", len(sites), "sites")
