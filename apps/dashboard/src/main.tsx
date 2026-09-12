import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  Activity, Boxes, BrainCircuit, CheckCircle2, Clipboard, Radar,
  SearchCheck, ShieldAlert, ShieldCheck, Wrench, Zap
} from 'lucide-react'
import './styles.css'

type Incident = {
  id: string
  status: string
  created_at: string
  updated_at: string
  evidence: { alert_name: string; annotations: Record<string, string> }
  diagnosis?: { probable_cause: string; confidence: number }
  plan?: { action: string; risk: string; namespace: string; target_name: string }
  policy?: { result: string; reason: string }
  remediation_result?: { success: boolean; message: string; details: Record<string, unknown> }
}
type AgentStatus = {
  name: string
  status: string
  message: string
  incident_id?: string
  details: Record<string, unknown>
  updated_at: string
}
type AgentActivity = {
  id: string
  agent_name: string
  status: string
  message: string
  incident_id?: string
  details: Record<string, unknown>
  created_at: string
}

const API = '/api/v1'
const agentDefinitions = [
  {name: 'detector', label: 'Detector', icon: Radar, idle: 'Watching Prometheus'},
  {name: 'ai-reasoner', label: 'AI Reasoner', icon: BrainCircuit, idle: 'Waiting for evidence'},
  {name: 'planner', label: 'Planner', icon: Activity, idle: 'Waiting for a diagnosis'},
  {name: 'policy-guard', label: 'OPA Policy', icon: ShieldCheck, idle: 'Waiting for a plan'},
  {name: 'remediation-controller', label: 'Remediator', icon: Wrench, idle: 'Waiting for approval'},
  {name: 'recovery-verifier', label: 'Verifier', icon: SearchCheck, idle: 'Waiting for remediation'},
]

function App() {
  const [incidents, setIncidents] = useState<Incident[]>([])
  const [agents, setAgents] = useState<AgentStatus[]>([])
  const [activity, setActivity] = useState<AgentActivity[]>([])
  const [selected, setSelected] = useState<Incident | null>(null)
  const [copied, setCopied] = useState('')

  async function refresh() {
    const [incidentsResponse, agentsResponse, activityResponse] = await Promise.all([
      fetch(`${API}/incidents`),
      fetch(`${API}/agents`),
      fetch(`${API}/activity`),
    ])
    if (incidentsResponse.ok) setIncidents(await incidentsResponse.json())
    if (agentsResponse.ok) setAgents(await agentsResponse.json())
    if (activityResponse.ok) setActivity(await activityResponse.json())
  }

  useEffect(() => {
    refresh()
    const timer = setInterval(refresh, 2000)
    return () => clearInterval(timer)
  }, [])

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

  async function copy(command: string) {
    await navigator.clipboard.writeText(command)
    setCopied(command)
    setTimeout(() => setCopied(''), 1800)
  }

  async function decide(kind: 'approve'|'reject') {
    if (!selected) return
    const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('token') || ''
    const response = await fetch(`${API}/incidents/${selected.id}/${kind}`, {
      method: 'POST',
      headers: {'content-type':'application/json'},
      body: JSON.stringify({token}),
    })
    if (response.ok) refresh()
    else alert(await response.text())
  }

  return <div className="shell">
    <header>
      <div><span className="eyebrow">CHEIKHAILABS</span><h1>Autonomous SRE</h1></div>
      <div className="header-actions">
        <span className="live"><i/>LIVE · 2S</span>
        <a className="cluster-link" href="/kubernetes/"><Boxes size={17}/>Kubernetes Explorer</a>
        <div className="mode">AUTONOMOUS LOW RISK</div>
      </div>
    </header>

    <section className="grid stats">
      <Card icon={<Activity/>} label="Active incidents" value={stats.active}/>
      <Card icon={<CheckCircle2/>} label="Recovered" value={stats.recovered}/>
      <Card icon={<ShieldAlert/>} label="Pending approvals" value={stats.approvals}/>
      <Card icon={<Zap/>} label="Autonomous recoveries" value={stats.autonomous}/>
    </section>

    <section className="panel">
      <div className="panel-head">
        <div><span className="section-kicker">CONTROL PLANE</span><h2>Agent operations</h2></div>
        <span className="muted">Persistent activity journal</span>
      </div>
      <div className="agents">
        {agentDefinitions.map(definition => {
          const state = agents.find(item => item.name === definition.name)
          const Icon = definition.icon
          const status = state?.status || 'idle'
          return <article className={`agent ${status}`} key={definition.name}>
            <div className="agent-top">
              <div className="agent-icon"><Icon size={19}/></div>
              <span className={`status ${status}`}>{status}</span>
            </div>
            <h3>{definition.label}</h3>
            <p>{state?.message || definition.idle}</p>
            <small>{state ? new Date(state.updated_at).toLocaleTimeString() : 'No activity yet'}</small>
          </article>
        })}
      </div>
    </section>

    <div className="operations-grid">
      <section className="panel timeline-panel">
        <div className="panel-head">
          <div><span className="section-kicker">REAL TIME</span><h2>Agent activity</h2></div>
        </div>
        <div className="timeline">
          {activity.length === 0 && <div className="empty">No agent event yet. Start the golden-path test.</div>}
          {activity.slice(0, 18).map(item => <div className="event" key={item.id}>
            <span className={`event-dot ${item.status}`}/>
            <div>
              <div className="event-head">
                <strong>{item.agent_name}</strong>
                <time>{new Date(item.created_at).toLocaleTimeString()}</time>
              </div>
              <p>{item.message}</p>
              {item.incident_id && <small>Incident {item.incident_id.slice(0, 8)}</small>}
            </div>
          </div>)}
        </div>
      </section>

      <section className="panel tests-panel">
        <div className="panel-head">
          <div><span className="section-kicker">VALIDATION</span><h2>Test scenarios</h2></div>
        </div>
        <div className="scenario">
          <div><h3>Pod recovery</h3><p>Deletes one managed demo Pod and verifies Kubernetes replacement.</p></div>
          <button onClick={() => copy('make chaos-smoke')}><Clipboard size={15}/>{copied === 'make chaos-smoke' ? 'Copied' : 'Copy command'}</button>
        </div>
        <div className="scenario featured">
          <div><h3>Autonomous bad release</h3><p>Injects 85% HTTP errors and follows detection, AI diagnosis, OPA decision, rollback and recovery.</p></div>
          <button onClick={() => copy('make chaos-bad-release')}><Clipboard size={15}/>{copied === 'make chaos-bad-release' ? 'Copied' : 'Copy command'}</button>
        </div>
        <p className="safety-note">Commands run from your authenticated workstation. The public dashboard cannot trigger cluster mutations.</p>
      </section>
    </div>

    <section className="panel">
      <div className="panel-head">
        <div><span className="section-kicker">HISTORY</span><h2>Incidents</h2></div>
        <button onClick={refresh}>Refresh</button>
      </div>
      <div className="table">
        {incidents.length === 0 && <div className="empty">No incident recorded yet.</div>}
        {incidents.map(item => <button className="row" key={item.id} onClick={() => setSelected(item)}>
          <span className={`dot ${item.status}`}></span>
          <span>{item.evidence.alert_name}</span>
          <span>{item.status}</span>
          <span>{new Date(item.created_at).toLocaleString()}</span>
        </button>)}
      </div>
    </section>

    {selected && <section className="panel detail">
      <div className="panel-head"><h2>{selected.evidence.alert_name}</h2><span className="pill">{selected.status}</span></div>
      <div className="detail-grid">
        <div><h3>Root cause</h3><p>{selected.diagnosis?.probable_cause || 'Pending diagnosis'}</p><small>Confidence {Math.round((selected.diagnosis?.confidence || 0)*100)}%</small></div>
        <div><h3>Remediation</h3><p>{selected.plan?.action || 'No action'}</p><small>{selected.plan ? `${selected.plan.namespace}/${selected.plan.target_name} · ${selected.plan.risk}` : ''}</small></div>
        <div><h3>Policy</h3><p>{selected.policy?.result || 'Pending'}</p><small>{selected.policy?.reason}</small></div>
        <div><h3>Result</h3><p>{selected.remediation_result?.message || 'Pending'}</p></div>
      </div>
      {selected.status === 'pending_approval' && <div className="actions"><button className="approve" onClick={() => decide('approve')}>Approve</button><button className="reject" onClick={() => decide('reject')}>Reject</button></div>}
    </section>}
  </div>
}

function Card({icon,label,value}:{icon:React.ReactNode,label:string,value:number}) {
  return <div className="card"><div className="icon">{icon}</div><div><span>{label}</span><strong>{value}</strong></div></div>
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>)
