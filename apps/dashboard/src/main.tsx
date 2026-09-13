import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  Activity, ArrowRight, Boxes, BrainCircuit, CheckCircle2, ChevronRight,
  Clock3, Download, ExternalLink, FileText, Mail, Radar, RefreshCw,
  SearchCheck, ShieldAlert, ShieldCheck, Sparkles, Wrench, X, Zap
} from 'lucide-react'
import './styles.css'

type Incident = {
  id: string
  status: string
  created_at: string
  updated_at: string
  evidence: {
    alert_name: string
    annotations: Record<string, string>
    observations?: string[]
    metric_samples?: Record<string, number>
  }
  diagnosis?: {
    probable_cause: string
    confidence: number
    evidence?: string[]
    rationale?: string
    affected_resources?: string[]
  }
  plan?: {
    action: string
    risk: string
    namespace: string
    target_name: string
    target_kind?: string
    blast_radius?: number
    parameters?: Record<string, unknown>
  }
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

type SystemStatus = {
  environment: string
  mode: string
  poll_interval_seconds: number
  mail_enabled: boolean
  report_recipient?: string | null
  event_delivery?: string
}

type EmailDelivery = {
  status: string
  message?: string | null
  recipient?: string | null
  updated_at?: string | null
}

type IncidentReport = {
  report_type: string
  generated_at: string
  incident_id: string
  status: string
  started_at: string
  finished_at: string
  duration_seconds: number
  email_delivery: EmailDelivery
  timeline: AgentActivity[]
}

const API = '/api/v1'
const HEADLAMP_URL = '/kubernetes/'

const agentDefinitions = [
  {name: 'detector', label: 'Detector', icon: Radar, idle: 'Watching Prometheus'},
  {name: 'ai-reasoner', label: 'AI Reasoner', icon: BrainCircuit, idle: 'Waiting for evidence'},
  {name: 'planner', label: 'Planner', icon: Activity, idle: 'Waiting for a diagnosis'},
  {name: 'policy-guard', label: 'Policy Guard', icon: ShieldCheck, idle: 'Waiting for a plan'},
  {name: 'remediation-controller', label: 'Remediator', icon: Wrench, idle: 'Waiting for work'},
  {name: 'recovery-verifier', label: 'Verifier', icon: SearchCheck, idle: 'Waiting for remediation'},
]

const terminalStatuses = new Set(['recovered', 'rejected', 'blocked', 'failed'])

function formatDuration(seconds: number) {
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  const rest = seconds % 60
  if (minutes < 60) return `${minutes}m ${rest}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

function titleCase(value: string) {
  return value.replaceAll('_', ' ').replace(/\b\w/g, char => char.toUpperCase())
}

function emailDeliveryLabel(status?: string) {
  switch (status) {
    case 'success': return 'Delivered'
    case 'error': return 'Failed'
    case 'skipped': return 'Skipped'
    case 'not_attempted': return 'Not attempted'
    default: return status ? titleCase(status) : '…'
  }
}

function App() {
  const [incidents, setIncidents] = useState<Incident[]>([])
  const [agents, setAgents] = useState<AgentStatus[]>([])
  const [activity, setActivity] = useState<AgentActivity[]>([])
  const [system, setSystem] = useState<SystemStatus | null>(null)
  const [selected, setSelected] = useState<Incident | null>(null)
  const [report, setReport] = useState<IncidentReport | null>(null)
  const [detailTab, setDetailTab] = useState<'overview'|'timeline'|'report'>('overview')
  const [loading, setLoading] = useState(true)
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null)

  async function refresh() {
    try {
      const [incidentsResponse, agentsResponse, activityResponse, systemResponse] = await Promise.all([
        fetch(`${API}/incidents`),
        fetch(`${API}/agents`),
        fetch(`${API}/activity`),
        fetch(`${API}/system`),
      ])
      if (incidentsResponse.ok) setIncidents(await incidentsResponse.json())
      if (agentsResponse.ok) setAgents(await agentsResponse.json())
      if (activityResponse.ok) setActivity(await activityResponse.json())
      if (systemResponse.ok) setSystem(await systemResponse.json())
      setLastRefresh(new Date())
    } finally {
      setLoading(false)
    }
  }

  async function openIncident(item: Incident) {
    setSelected(item)
    setReport(null)
    setDetailTab('overview')
    history.replaceState({}, '', `/incidents/${item.id}${location.hash}`)
    const [incidentResponse, reportResponse] = await Promise.all([
      fetch(`${API}/incidents/${item.id}`),
      fetch(`${API}/incidents/${item.id}/report`),
    ])
    if (incidentResponse.ok) setSelected(await incidentResponse.json())
    if (reportResponse.ok) setReport(await reportResponse.json())
  }

  function closeIncident() {
    setSelected(null)
    setReport(null)
    history.replaceState({}, '', '/')
  }

  useEffect(() => {
    refresh()
    const timer = setInterval(refresh, 2000)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    const parts = location.pathname.split('/').filter(Boolean)
    const id = parts[0] === 'incidents' ? parts[1] : null
    if (!id) return
    fetch(`${API}/incidents/${id}`)
      .then(r => r.ok ? r.json() : null)
      .then(item => item && openIncident(item))
  }, [])

  const stats = useMemo(() => ({
    active: incidents.filter(i => !terminalStatuses.has(i.status)).length,
    recovered: incidents.filter(i => i.status === 'recovered').length,
    approvals: incidents.filter(i => i.status === 'pending_approval').length,
    autonomous: incidents.filter(i => i.status === 'recovered' && ['low','medium'].includes(i.plan?.risk || '')).length,
  }), [incidents])

  const currentIncident = incidents.find(item => !terminalStatuses.has(item.status))
  const recentActivity = activity.slice(0, 14)
  const reportEmail = report?.email_delivery
  const reportEmailDetail = reportEmail?.recipient
    ? `${reportEmail.message || 'Email delivery recorded'} · ${reportEmail.recipient}`
    : reportEmail?.message || (system?.mail_enabled ? 'Waiting for incident delivery status.' : 'SMTP is not configured.')

  async function decide(kind: 'approve'|'reject') {
    if (!selected) return
    const token = new URLSearchParams(location.hash.replace(/^#/, '')).get('token') || ''
    const response = await fetch(`${API}/incidents/${selected.id}/${kind}`, {
      method: 'POST',
      headers: {'content-type':'application/json'},
      body: JSON.stringify({token}),
    })
    if (!response.ok) {
      alert(await response.text())
      return
    }
    await refresh()
    const updated = await fetch(`${API}/incidents/${selected.id}`)
    if (updated.ok) setSelected(await updated.json())
  }

  function downloadReport() {
    if (!report || !selected) return
    const blob = new Blob([JSON.stringify(report, null, 2)], {type: 'application/json'})
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `autonomous-sre-${selected.id}.json`
    link.click()
    URL.revokeObjectURL(url)
  }

  const modeLabel = system?.mode === 'autonomous-low-risk'
    ? 'Autonomous · low + medium risk'
    : titleCase(system?.mode || 'Loading')

  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand">
        <div className="brand-mark"><Sparkles size={18}/></div>
        <div><span>CHEIKHAILABS</span><strong>Autonomous SRE</strong></div>
      </div>

      <nav>
        <a className="nav-item active" href="/"><Activity size={17}/>Command Center</a>
        <a className="nav-item" href={HEADLAMP_URL} target="_blank" rel="noreferrer" title="Open Kubernetes Explorer"><Boxes size={17}/>Kubernetes</a>
      </nav>

      <div className="sidebar-status">
        <span className="sidebar-label">AUTONOMY</span>
        <div className="autonomy-status"><i/>{modeLabel}</div>
        <p>Low and medium impact remediations can run without human intervention. High impact actions require approval.</p>
      </div>
    </aside>

    <main className="main">
      <header className="topbar">
        <div>
          <span className="eyebrow">SRE COMMAND CENTER</span>
          <h1>Operations overview</h1>
          <p>Detection, reasoning and remediation across your Kubernetes platform.</p>
        </div>
        <div className="topbar-actions">
          <span className="live-pill"><i/>Live · 2s</span>
          <button className="icon-button" onClick={refresh} title="Refresh now"><RefreshCw size={17}/></button>
          <a className="primary-link" href={HEADLAMP_URL} target="_blank" rel="noreferrer" title="Open Kubernetes Explorer"><Boxes size={16}/>Explore cluster<ExternalLink size={14}/></a>
        </div>
      </header>

      {currentIncident && <section className="active-banner">
        <div className="active-icon"><Zap size={19}/></div>
        <div className="active-copy">
          <span>ACTIVE INTERVENTION</span>
          <strong>{currentIncident.evidence.alert_name}</strong>
          <p>{currentIncident.diagnosis?.probable_cause || 'Evidence collection and diagnosis in progress.'}</p>
        </div>
        <div className="active-meta">
          <span className={`status-chip ${currentIncident.status}`}>{titleCase(currentIncident.status)}</span>
          <button onClick={() => openIncident(currentIncident)}>Open incident<ArrowRight size={15}/></button>
        </div>
      </section>}

      <section className="metric-grid">
        <Metric icon={<ShieldAlert/>} label="Active incidents" value={stats.active} sub="Requires attention now"/>
        <Metric icon={<CheckCircle2/>} label="Recovered" value={stats.recovered} sub="Closed interventions"/>
        <Metric icon={<Clock3/>} label="Approvals" value={stats.approvals} sub="High-impact only"/>
        <Metric icon={<Zap/>} label="Autonomous fixes" value={stats.autonomous} sub="Low + medium risk"/>
      </section>

      <section className="system-strip">
        <SystemItem label="Environment" value={system?.environment || '…'} state="neutral"/>
        <SystemItem label="Control loop" value={system ? `${system.poll_interval_seconds}s interval` : '…'} state="good"/>
        <SystemItem label="Event bus" value={system?.event_delivery === 'jetstream-durable' ? 'JetStream durable' : '…'} state={system?.event_delivery === 'jetstream-durable' ? 'good' : 'warn'}/>
        <SystemItem label="Post-incident email" value={system?.mail_enabled ? 'Enabled' : 'Not configured'} state={system?.mail_enabled ? 'good' : 'warn'}/>
        <SystemItem label="Report recipient" value={system?.mail_enabled ? (system.report_recipient || 'Configured') : 'SMTP credentials required'} state="neutral"/>
      </section>

      <section className="panel agents-panel">
        <PanelTitle kicker="CONTROL PLANE" title="Agent operations" detail="Live status of the autonomous workflow"/>
        <div className="agent-grid">
          {agentDefinitions.map(definition => {
            const state = agents.find(item => item.name === definition.name)
            const Icon = definition.icon
            const status = state?.status || 'idle'
            return <article className={`agent-card ${status}`} key={definition.name}>
              <div className="agent-card-top">
                <div className="agent-icon"><Icon size={18}/></div>
                <span className={`agent-state ${status}`}>{titleCase(status)}</span>
              </div>
              <h3>{definition.label}</h3>
              <p>{state?.message || definition.idle}</p>
              <small>{state ? new Date(state.updated_at).toLocaleTimeString() : 'No activity yet'}</small>
            </article>
          })}
        </div>
      </section>

      <div className="content-grid">
        <section className="panel activity-panel">
          <PanelTitle kicker="LIVE JOURNAL" title="Agent activity" detail={lastRefresh ? `Updated ${lastRefresh.toLocaleTimeString()}` : ''}/>
          <div className="timeline">
            {recentActivity.length === 0 && <Empty label="No agent events yet."/>}
            {recentActivity.map(item => <div className="timeline-item" key={item.id}>
              <div className={`timeline-dot ${item.status}`}/>
              <div className="timeline-body">
                <div className="timeline-head"><strong>{titleCase(item.agent_name)}</strong><time>{new Date(item.created_at).toLocaleTimeString()}</time></div>
                <p>{item.message}</p>
                {item.incident_id && <button className="inline-link" onClick={() => {
                  const incident = incidents.find(i => i.id === item.incident_id)
                  if (incident) openIncident(incident)
                }}>Incident {item.incident_id.slice(0,8)}<ChevronRight size={13}/></button>}
              </div>
            </div>)}
          </div>
        </section>

        <section className="panel posture-panel">
          <PanelTitle kicker="AUTONOMY POLICY" title="Remediation posture"/>
          <div className="posture-list">
            <PostureRow icon={<CheckCircle2/>} title="Automatic" detail="Restart, rollback, pod replacement, guarded scaling, StatefulSet and DaemonSet recovery, node uncordon." tone="good"/>
            <PostureRow icon={<ShieldAlert/>} title="Approval required" detail="High-impact actions such as cordoning a node." tone="warn"/>
            <PostureRow icon={<ShieldCheck/>} title="Blocked" detail="Namespace deletion, infrastructure destruction and node draining." tone="danger"/>
          </div>
          <a className="secondary-link" href={HEADLAMP_URL} target="_blank" rel="noreferrer" title="Open Kubernetes Explorer"><Boxes size={15}/>Inspect live Kubernetes resources<ArrowRight size={14}/></a>
        </section>
      </div>

      <section className="panel incidents-panel">
        <PanelTitle kicker="HISTORY" title="Incidents" detail={`${incidents.length} recorded`}/>
        <div className="incident-table">
          <div className="table-header"><span>Incident</span><span>Status</span><span>Action</span><span>Risk</span><span>Started</span><span/></div>
          {incidents.length === 0 && <Empty label={loading ? 'Loading incidents…' : 'No incidents recorded yet.'}/>} 
          {incidents.map(item => <button className="incident-row" key={item.id} onClick={() => openIncident(item)}>
            <span className="incident-name"><i className={`health-dot ${item.status}`}/><span><strong>{item.evidence.alert_name}</strong><small>{item.id.slice(0,8)}</small></span></span>
            <span><span className={`status-chip ${item.status}`}>{titleCase(item.status)}</span></span>
            <span className="mono">{item.plan?.action ? titleCase(item.plan.action) : 'Pending'}</span>
            <span><span className={`risk ${item.plan?.risk || 'unknown'}`}>{item.plan?.risk || 'unknown'}</span></span>
            <span className="muted-cell">{new Date(item.created_at).toLocaleString()}</span>
            <span className="row-arrow"><ChevronRight size={17}/></span>
          </button>)}
        </div>
      </section>
    </main>

    {selected && <div className="drawer-backdrop" onMouseDown={event => {
      if (event.currentTarget === event.target) closeIncident()
    }}>
      <aside className="incident-drawer">
        <div className="drawer-header">
          <div>
            <span className="eyebrow">INCIDENT {selected.id.slice(0,8)}</span>
            <h2>{selected.evidence.alert_name}</h2>
            <div className="drawer-meta"><span className={`status-chip ${selected.status}`}>{titleCase(selected.status)}</span><span>{new Date(selected.created_at).toLocaleString()}</span></div>
          </div>
          <button className="close-button" onClick={closeIncident}><X size={19}/></button>
        </div>

        <div className="drawer-tabs">
          {(['overview','timeline','report'] as const).map(tab => <button className={detailTab === tab ? 'active' : ''} onClick={() => setDetailTab(tab)} key={tab}>{titleCase(tab)}</button>)}
        </div>

        <div className="drawer-content">
          {detailTab === 'overview' && <>
            <section className="summary-hero">
              <span>AI ROOT CAUSE</span>
              <h3>{selected.diagnosis?.probable_cause || 'Diagnosis in progress'}</h3>
              <div className="confidence"><div><i style={{width: `${Math.round((selected.diagnosis?.confidence || 0) * 100)}%`}}/></div><strong>{Math.round((selected.diagnosis?.confidence || 0) * 100)}% confidence</strong></div>
              {selected.diagnosis?.rationale && <p>{selected.diagnosis.rationale}</p>}
            </section>

            <div className="detail-card-grid">
              <DetailCard label="Remediation" value={selected.plan?.action ? titleCase(selected.plan.action) : 'Pending'} detail={selected.plan ? `${selected.plan.target_kind || 'Resource'} · ${selected.plan.namespace}/${selected.plan.target_name}` : undefined}/>
              <DetailCard label="Risk" value={selected.plan?.risk ? titleCase(selected.plan.risk) : 'Pending'} detail={selected.plan?.blast_radius ? `Blast radius ${selected.plan.blast_radius}` : undefined}/>
              <DetailCard label="Policy decision" value={selected.policy?.result ? titleCase(selected.policy.result) : 'Pending'} detail={selected.policy?.reason}/>
              <DetailCard label="Result" value={selected.remediation_result?.success ? 'Recovered' : selected.remediation_result?.message || 'Pending'} detail={selected.remediation_result?.message}/>
            </div>

            {selected.diagnosis?.evidence && selected.diagnosis.evidence.length > 0 && <section className="drawer-section">
              <h3>Evidence used by the reasoner</h3>
              <div className="evidence-list">{selected.diagnosis.evidence.map((value, index) => <div key={index}><SearchCheck size={15}/><span>{value}</span></div>)}</div>
            </section>}

            {selected.status === 'pending_approval' && <section className="approval-box">
              <div><ShieldAlert size={20}/><div><strong>Human decision required</strong><p>This action is classified high impact. Review the target and remediation before continuing.</p></div></div>
              <div className="approval-actions"><button className="reject-button" onClick={() => decide('reject')}>Reject</button><button className="approve-button" onClick={() => decide('approve')}>Approve remediation</button></div>
            </section>}
          </>}

          {detailTab === 'timeline' && <section className="drawer-section">
            <h3>Intervention timeline</h3>
            <div className="report-timeline">
              {(report?.timeline || activity.filter(item => item.incident_id === selected.id)).map(item => <div className="report-event" key={item.id}>
                <i className={item.status}/><div><div><strong>{titleCase(item.agent_name)}</strong><time>{new Date(item.created_at).toLocaleTimeString()}</time></div><p>{item.message}</p></div>
              </div>)}
              {(report?.timeline || activity.filter(item => item.incident_id === selected.id)).length === 0 && <Empty label="No timeline events recorded for this incident."/>}
            </div>
          </section>}

          {detailTab === 'report' && <>
            <section className="report-hero">
              <div className="report-icon"><FileText size={22}/></div>
              <div><span>POST-INCIDENT REPORT</span><h3>Intervention summary ready</h3><p>The report contains diagnosis, policy decision, remediation result and the complete agent timeline.</p></div>
            </section>
            <div className="report-stats">
              <DetailCard label="Duration" value={report ? formatDuration(report.duration_seconds) : '…'}/>
              <DetailCard label="Final state" value={titleCase(selected.status)}/>
              <DetailCard label="Email delivery" value={emailDeliveryLabel(reportEmail?.status)} detail={reportEmailDetail}/>
            </div>
            <div className="report-actions">
              <button className="download-button" onClick={downloadReport} disabled={!report}><Download size={16}/>Download JSON report</button>
              {system?.mail_enabled && <div className="mail-note"><Mail size={15}/>Closing-report delivery is tracked for this incident.</div>}
            </div>
          </>}
        </div>
      </aside>
    </div>}
  </div>
}

function Metric({icon,label,value,sub}:{icon:React.ReactNode,label:string,value:number,sub:string}) {
  return <article className="metric-card"><div className="metric-icon">{icon}</div><div><span>{label}</span><strong>{value}</strong><small>{sub}</small></div></article>
}

function SystemItem({label,value,state}:{label:string,value:string,state:'good'|'warn'|'neutral'}) {
  return <div className="system-item"><span>{label}</span><strong className={state}><i/>{value}</strong></div>
}

function PanelTitle({kicker,title,detail}:{kicker:string,title:string,detail?:string}) {
  return <div className="panel-title"><div><span>{kicker}</span><h2>{title}</h2></div>{detail && <small>{detail}</small>}</div>
}

function PostureRow({icon,title,detail,tone}:{icon:React.ReactNode,title:string,detail:string,tone:string}) {
  return <div className={`posture-row ${tone}`}><div className="posture-icon">{icon}</div><div><strong>{title}</strong><p>{detail}</p></div></div>
}

function DetailCard({label,value,detail}:{label:string,value:string,detail?:string}) {
  return <div className="detail-card"><span>{label}</span><strong>{value}</strong>{detail && <p>{detail}</p>}</div>
}

function Empty({label}:{label:string}) {
  return <div className="empty-state">{label}</div>
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>)
