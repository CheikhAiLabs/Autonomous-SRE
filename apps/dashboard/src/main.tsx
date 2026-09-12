import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { Activity, CheckCircle2, ShieldAlert, Zap } from 'lucide-react'
import './styles.css'

type Incident = {
  id: string
  status: string
  created_at: string
  evidence: { alert_name: string; annotations: Record<string, string> }
  diagnosis?: { probable_cause: string; confidence: number }
  plan?: { action: string; risk: string; namespace: string; target_name: string }
  policy?: { result: string; reason: string }
}

const API = '/api/v1'

function App() {
  const [incidents, setIncidents] = useState<Incident[]>([])
  const [selected, setSelected] = useState<Incident | null>(null)

  async function refresh() {
    const r = await fetch(`${API}/incidents`)
    if (r.ok) setIncidents(await r.json())
  }

  useEffect(() => { refresh(); const t = setInterval(refresh, 5000); return () => clearInterval(t) }, [])
  useEffect(() => {
    const parts = location.pathname.split('/').filter(Boolean)
    const id = parts[0] === 'incidents' ? parts[1] : null
    if (id) fetch(`${API}/incidents/${id}`).then(r => r.ok ? r.json() : null).then(setSelected)
  }, [])

  const stats = useMemo(() => ({
    active: incidents.filter(i => !['recovered','rejected','blocked'].includes(i.status)).length,
    recovered: incidents.filter(i => i.status === 'recovered').length,
    approvals: incidents.filter(i => i.status === 'pending_approval').length,
    autonomous: incidents.filter(i => i.status === 'recovered' && i.plan?.risk === 'low').length,
  }), [incidents])

  async function decide(kind: 'approve'|'reject') {
    if (!selected) return
    const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('token') || ''
    const r = await fetch(`${API}/incidents/${selected.id}/${kind}`, {
      method: 'POST', headers: {'content-type':'application/json'}, body: JSON.stringify({token})
    })
    if (r.ok) location.reload()
    else alert(await r.text())
  }

  return <div className="shell">
    <header><div><span className="eyebrow">CHEIKHAILABS</span><h1>Autonomous SRE</h1></div><div className="mode">AUTONOMOUS LOW RISK</div></header>
    <section className="grid stats">
      <Card icon={<Activity/>} label="Active incidents" value={stats.active}/>
      <Card icon={<CheckCircle2/>} label="Recovered" value={stats.recovered}/>
      <Card icon={<ShieldAlert/>} label="Pending approvals" value={stats.approvals}/>
      <Card icon={<Zap/>} label="Autonomous recoveries" value={stats.autonomous}/>
    </section>
    <section className="panel">
      <div className="panel-head"><h2>Incidents</h2><button onClick={refresh}>Refresh</button></div>
      <div className="table">
        {incidents.map(i => <button className="row" key={i.id} onClick={() => setSelected(i)}>
          <span className={`dot ${i.status}`}></span><span>{i.evidence.alert_name}</span><span>{i.status}</span><span>{new Date(i.created_at).toLocaleString()}</span>
        </button>)}
      </div>
    </section>
    {selected && <section className="panel detail">
      <div className="panel-head"><h2>{selected.evidence.alert_name}</h2><span className="pill">{selected.status}</span></div>
      <div className="detail-grid">
        <div><h3>Root cause</h3><p>{selected.diagnosis?.probable_cause || 'Pending diagnosis'}</p><small>Confidence {Math.round((selected.diagnosis?.confidence || 0)*100)}%</small></div>
        <div><h3>Remediation</h3><p>{selected.plan?.action || 'No action'}</p><small>{selected.plan ? `${selected.plan.namespace}/${selected.plan.target_name} · ${selected.plan.risk}` : ''}</small></div>
        <div><h3>Policy</h3><p>{selected.policy?.result || 'Pending'}</p><small>{selected.policy?.reason}</small></div>
      </div>
      {selected.status === 'pending_approval' && <div className="actions"><button className="approve" onClick={() => decide('approve')}>Approve</button><button className="reject" onClick={() => decide('reject')}>Reject</button></div>}
    </section>}
  </div>
}

function Card({icon,label,value}:{icon:React.ReactNode,label:string,value:number}) { return <div className="card"><div className="icon">{icon}</div><div><span>{label}</span><strong>{value}</strong></div></div> }

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>)
