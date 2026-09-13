import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  Activity, ArrowRight, Boxes, BrainCircuit, CheckCircle2, ChevronRight,
  CircleDot, Clock3, Download, ExternalLink, FileText, Mail, Radar, RefreshCw,
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

type VisualState = 'complete' | 'active' | 'queued' | 'approval' | 'error' | 'idle'

type PipelineStage = {
  name: string
  label: string
  icon: React.ComponentType<{size?: number}>
  state: VisualState
  message: string
  time?: string
}

const API = '/api/v1'
const HEADLAMP_URL = '/kubernetes/'

const agentDefinitions = [
  {name: 'detector', label: 'Detect', icon: Radar, idle: 'Watching Prometheus'},
  {name: 'ai-reasoner', label: 'Reason', icon: BrainCircuit, idle: 'Waiting for evidence'},
  {name: 'planner', label: 'Plan', icon: Activity, idle: 'Waiting for a diagnosis'},
  {name: 'policy-guard', label: 'Guard', icon: ShieldCheck, idle: 'Waiting for a plan'},
  {name: 'remediation-controller', label: 'Remediate', icon: Wrench, idle: 'Waiting for work'},
  {name: 'recovery-verifier', label: 'Verify', icon: SearchCheck, idle: 'Waiting for remediation'},
]

const terminalStatuses = new Set(['recovered', 'rejected', 'blocked', 'failed'])
const failureStatuses = new Set(['failed', 'error', 'blocked', 'deny', 'rejected'])

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

function timeAgo(value?: string) {
  if (!value) return 'No activity yet'
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000))
  if (seconds < 10) return 'just now'
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
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

function visualFromStatus(status?: string): VisualState {
  const normalized = (status || '').toLowerCase()
  if (['success', 'recovered', 'watching', 'allow', 'completed'].includes(normalized)) return 'complete'
  if (['working', 'active', 'running', 'diagnosing', 'planning', 'remediating', 'verifying'].includes(normalized)) return 'active'
  if (['pending_approval', 'approval', 'awaiting_approval'].includes(normalized)) return 'approval'
  if (failureStatuses.has(normalized)) return 'error'
  if (normalized === 'idle') return 'idle'
  return normalized ? 'active' : 'queued'
}

function visualLabel(state: VisualState) {
  switch (state) {
    case 'complete': return 'Complete'
    case 'active': return 'Running'
    case 'approval': return 'Approval'
    case 'error': return 'Failed'
    case 'queued': return 'Queued'
    default: return 'Standby'
  }
}

function incidentTone(status?: string) {
  if (status === 'recovered') return 'success'
  if (['failed', 'rejected', 'blocked'].includes(status || '')) return 'danger'
  if (status === 'pending_approval') return 'warning'
  return 'active'
}

function inferredStageState(incident: Incident | undefined, index: number): VisualState {
  if (!incident) return 'idle'
  if (incident.status === 'recovered') return 'complete'

  if (incident.status === 'blocked') {
    if (index < 3) return 'complete'
    if (index === 3) return 'error'
    return 'queued'
  }

  if (incident.status === 'rejected') {
    if (index < 4) return 'complete'
    if (index === 4) return 'error'
    return 'queued'
  }

  if (incident.status === 'failed') {
    if (incident.remediation_result) {
      if (index < 5) return 'complete'
      return 'error'
    }
    if (incident.policy) {
      if (index < 4) return 'complete'
      return index === 4 ? 'error' : 'queued'
    }
    if (incident.plan) {
      if (index < 3) return 'complete'
      return index === 3 ? 'error' : 'queued'
    }
    if (incident.diagnosis) {
      if (index < 2) return 'complete'
      return index === 2 ? 'error' : 'queued'
    }
    return index === 0 ? 'complete' : index === 1 ? 'error' : 'queued'
  }

  if (incident.status === 'remediating') {
    if (index < 4) return 'complete'
    return index === 4 ? 'active' : 'queued'
  }

  if (incident.status === 'pending_approval') {
    if (index < 4) return 'complete'
    return index === 4 ? 'approval' : 'queued'
  }

  if (incident.status === 'diagnosed') {
    if (index < 2) return 'complete'
    return index === 2 ? 'active' : 'queued'
  }

  if (incident.status === 'open') {
    if (index === 0) return 'complete'
    return index === 1 ? 'active' : 'queued'
  }

  return 'queued'
}

function buildPipelineStages(
  incident: Incident | undefined,
  events: AgentActivity[],
  agents: AgentStatus[],
): PipelineStage[] {
  return agentDefinitions.map((definition, index) => {
    const event = incident
      ? events.find(item => item.incident_id === incident.id && item.agent_name === definition.name)
      : undefined
    const liveState = agents.find(item => item.name === definition.name)
    const eventState = event ? visualFromStatus(event.status) : undefined
    const associatedLiveState = liveState?.incident_id === incident?.id ? visualFromStatus(liveState.status) : undefined
    const state = eventState && eventState !== 'idle'
      ? eventState
      : associatedLiveState && associatedLiveState !== 'idle'
        ? associatedLiveState
        : inferredStageState(incident, index)

    let message = definition.idle
    let time = liveState?.updated_at
    if (event) {
      message = event.message
      time = event.created_at
    } else if (liveState?.incident_id === incident?.id) {
      message = liveState.message
    } else if (incident?.status === 'recovered' && state === 'complete') {
      message = 'Completed successfully'
    } else if (state === 'queued') {
      message = 'Waiting for previous stage'
    } else if (state === 'approval') {
      message = 'Human approval required'
    }

    return {...definition, state, message, time}
  })
}

function pipelineProgress(stages: PipelineStage[]) {
  if (stages.length === 0) return 0
  const score = stages.reduce((total, stage) => {
    if (stage.state === 'complete' || stage.state === 'error') return total + 1
    if (stage.state === 'active' || stage.state === 'approval') return total + 0.55
    return total
  }, 0)
  return Math.round((score / stages.length) * 100)
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
  const [refreshing, setRefreshing] = useState(false)

  async function refresh() {
    setRefreshing(true)
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
      setRefreshing(false)
    }
  }

  async function refreshIncident(incidentId: string) {
    const [incidentResponse, reportResponse] = await Promise.all([
      fetch(`${API}/incidents/${incidentId}`),
      fetch(`${API}/incidents/${incidentId}/report`),
    ])
    if (incidentResponse.ok) setSelected(await incidentResponse.json())
    if (reportResponse.ok) setReport(await reportResponse.json())
  }

  async function openIncident(item: Incident) {
    setSelected(item)
    setReport(null)
    setDetailTab('overview')
    history.replaceState({}, '', `/incidents/${item.id}${location.hash}`)
    await refreshIncident(item.id)
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

  useEffect(() => {
    if (!selected?.id) return
    const timer = setInterval(() => refreshIncident(selected.id), 2000)
    return () => clearInterval(timer)
  }, [selected?.id])

  const stats = useMemo(() => ({
    active: incidents.filter(i => !terminalStatuses.has(i.status)).length,
    recovered: incidents.filter(i => i.status === 'recovered').length,
    approvals: incidents.filter(i => i.status === 'pending_approval').length,
    autonomous: incidents.filter(i => i.status === 'recovered' && ['low','medium'].includes(i.plan?.risk || '')).length,
  }), [incidents])

  const currentIncident = incidents.find(item => !terminalStatuses.has(item.status))
  const focusIncident = currentIncident || incidents[0]
  const focusEvents = focusIncident ? activity.filter(item => item.incident_id === focusIncident.id) : []
  const pipelineStages = useMemo(
    () => buildPipelineStages(focusIncident, activity, agents),
    [focusIncident, activity, agents],
  )
  const progress = focusIncident?.status === 'recovered' ? 100 : pipelineProgress(pipelineStages)
  const recentActivity = activity.slice(0, 16)
  const reportEmail = report?.email_delivery
  const reportEmailDetail = reportEmail?.recipient
    ? `${reportEmail.message || 'Email delivery recorded'} · ${reportEmail.recipient}`
    : reportEmail?.message || (system?.mail_enabled ? 'Waiting for incident delivery status.' : 'SMTP is not configured.')
  const selectedEvents = selected
    ? (report?.timeline || activity.filter(item => item.incident_id === selected.id))
    : []
  const selectedStages = useMemo(
    () => buildPipelineStages(selected || undefined, selectedEvents, agents),
    [selected, selectedEvents, agents],
  )

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
    await refreshIncident(selected.id)
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
          <h1>Autonomous operations</h1>
          <p>Live detection, reasoning, policy and remediation across your Kubernetes platform.</p>
        </div>
        <div className="topbar-actions">
          <span className="live-pill"><i/>Live · 2s</span>
          <button className={`icon-button ${refreshing ? 'refreshing' : ''}`} onClick={refresh} title="Refresh now"><RefreshCw size={17}/></button>
          <a className="primary-link" href={HEADLAMP_URL} target="_blank" rel="noreferrer" title="Open Kubernetes Explorer"><Boxes size={16}/>Explore cluster<ExternalLink size={14}/></a>
        </div>
      </header>

      {focusIncident && <section className={`intervention-hero tone-${incidentTone(focusIncident.status)}`}>
        <div className="intervention-main">
          <div className="intervention-kicker">
            <span className="hero-live-dot"/>
            {currentIncident ? 'INTERVENTION IN PROGRESS' : 'LATEST INTERVENTION'}
          </div>
          <div className="intervention-title-row">
            <div>
              <h2>{focusIncident.evidence.alert_name}</h2>
              <p>{focusIncident.diagnosis?.probable_cause || focusIncident.evidence.annotations?.summary || 'Collecting evidence and building a diagnosis.'}</p>
            </div>
            <span className={`status-chip status-large ${focusIncident.status}`}>{titleCase(focusIncident.status)}</span>
          </div>
          <div className="intervention-meta-row">
            <span><CircleDot size={13}/>{focusIncident.plan?.action ? titleCase(focusIncident.plan.action) : 'Action pending'}</span>
            <span><ShieldCheck size={13}/>{focusIncident.plan?.risk ? `${titleCase(focusIncident.plan.risk)} risk` : 'Risk pending'}</span>
            <span><Clock3 size={13}/>{timeAgo(focusIncident.updated_at)}</span>
          </div>
        </div>
        <div className="intervention-progress-card">
          <div className="progress-number"><strong>{progress}%</strong><span>{focusIncident.status === 'recovered' ? 'Recovered' : 'Workflow'}</span></div>
          <div className="progress-track"><i style={{width: `${progress}%`}}/></div>
          <button onClick={() => openIncident(focusIncident)}>Open intervention<ArrowRight size={15}/></button>
        </div>
      </section>}

      <section className="metric-grid">
        <Metric tone={stats.active > 0 ? 'active' : 'neutral'} icon={<ShieldAlert/>} label="Active incidents" value={stats.active} sub={stats.active > 0 ? 'Autonomous workflow running' : 'No active intervention'}/>
        <Metric tone="success" icon={<CheckCircle2/>} label="Recovered" value={stats.recovered} sub="Closed successfully"/>
        <Metric tone={stats.approvals > 0 ? 'warning' : 'neutral'} icon={<Clock3/>} label="Approvals" value={stats.approvals} sub="High-impact only"/>
        <Metric tone="info" icon={<Zap/>} label="Autonomous fixes" value={stats.autonomous} sub="Low + medium risk"/>
      </section>

      <section className="system-strip">
        <SystemItem label="Environment" value={system?.environment || '…'} state="neutral"/>
        <SystemItem label="Control loop" value={system ? `${system.poll_interval_seconds}s interval` : '…'} state="good"/>
        <SystemItem label="Event bus" value={system?.event_delivery === 'jetstream-durable' ? 'JetStream durable' : '…'} state={system?.event_delivery === 'jetstream-durable' ? 'good' : 'warn'}/>
        <SystemItem label="Post-incident email" value={system?.mail_enabled ? 'Enabled' : 'Not configured'} state={system?.mail_enabled ? 'good' : 'warn'}/>
        <SystemItem label="Report recipient" value={system?.mail_enabled ? (system.report_recipient || 'Configured') : 'SMTP credentials required'} state="neutral"/>
      </section>

      <section className="panel flow-panel">
        <PanelTitle
          kicker="AUTONOMOUS PIPELINE"
          title={currentIncident ? 'Live intervention flow' : 'Last intervention flow'}
          detail={focusIncident ? `${focusIncident.id.slice(0,8)} · ${titleCase(focusIncident.status)}` : 'Waiting for the first incident'}
        />
        <div className="pipeline-legend">
          <span className="legend-complete"><i/>Complete</span>
          <span className="legend-active"><i/>Running</span>
          <span className="legend-approval"><i/>Approval</span>
          <span className="legend-error"><i/>Failed</span>
          <span className="legend-queued"><i/>Queued</span>
        </div>
        <div className="pipeline-grid">
          {pipelineStages.map((stage, index) => <PipelineCard stage={stage} index={index} key={stage.name}/>)}
        </div>
      </section>

      <div className="content-grid">
        <section className="panel activity-panel">
          <PanelTitle kicker="LIVE JOURNAL" title="Agent activity" detail={lastRefresh ? `Updated ${lastRefresh.toLocaleTimeString()}` : ''}/>
          <div className="timeline">
            {recentActivity.length === 0 && <Empty label="No agent events yet."/>}
            {recentActivity.map(item => {
              const visual = visualFromStatus(item.status)
              return <div className={`timeline-item timeline-${visual}`} key={item.id}>
                <div className={`timeline-dot ${visual}`}/>
                <div className="timeline-body">
                  <div className="timeline-head">
                    <div><strong>{titleCase(item.agent_name)}</strong><span className={`activity-state ${visual}`}>{visualLabel(visual)}</span></div>
                    <time>{new Date(item.created_at).toLocaleTimeString()}</time>
                  </div>
                  <p>{item.message}</p>
                  {item.incident_id && <button className="inline-link" onClick={() => {
                    const incident = incidents.find(i => i.id === item.incident_id)
                    if (incident) openIncident(incident)
                  }}>Incident {item.incident_id.slice(0,8)}<ChevronRight size={13}/></button>}
                </div>
              </div>
            })}
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
        <PanelTitle kicker="INTERVENTION HISTORY" title="Incidents" detail={`${incidents.length} recorded`}/>
        <div className="incident-table">
          <div className="table-header"><span>Incident</span><span>Status</span><span>Action</span><span>Risk</span><span>Last update</span><span/></div>
          {incidents.length === 0 && <Empty label={loading ? 'Loading incidents…' : 'No incidents recorded yet.'}/>} 
          {incidents.map(item => <button className={`incident-row row-${incidentTone(item.status)}`} key={item.id} onClick={() => openIncident(item)}>
            <span className="incident-name"><i className={`health-dot ${item.status}`}/><span><strong>{item.evidence.alert_name}</strong><small>{item.id.slice(0,8)} · {new Date(item.created_at).toLocaleTimeString()}</small></span></span>
            <span><span className={`status-chip ${item.status}`}>{titleCase(item.status)}</span></span>
            <span className="mono">{item.plan?.action ? titleCase(item.plan.action) : 'Pending'}</span>
            <span><span className={`risk ${item.plan?.risk || 'unknown'}`}>{item.plan?.risk || 'unknown'}</span></span>
            <span className="muted-cell">{timeAgo(item.updated_at)}</span>
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
            <div className="drawer-meta"><span className={`status-chip ${selected.status}`}>{titleCase(selected.status)}</span><span>Updated {timeAgo(selected.updated_at)}</span></div>
          </div>
          <button className="close-button" onClick={closeIncident}><X size={19}/></button>
        </div>

        <div className="drawer-tabs">
          {(['overview','timeline','report'] as const).map(tab => <button className={detailTab === tab ? 'active' : ''} onClick={() => setDetailTab(tab)} key={tab}>{titleCase(tab)}</button>)}
        </div>

        <div className="drawer-content">
          {detailTab === 'overview' && <>
            <section className={`drawer-state-banner tone-${incidentTone(selected.status)}`}>
              <div><span>CURRENT STATE</span><strong>{titleCase(selected.status)}</strong></div>
              <p>{selected.remediation_result?.message || selected.policy?.reason || selected.diagnosis?.probable_cause || 'Autonomous workflow is processing this incident.'}</p>
            </section>

            <section className="drawer-flow-section">
              <div className="drawer-section-title"><span>INTERVENTION FLOW</span><small>{pipelineProgress(selectedStages)}% complete</small></div>
              <div className="drawer-pipeline">
                {selectedStages.map(stage => <div className={`drawer-stage ${stage.state}`} key={stage.name}><span>{stage.label}</span><i/><small>{visualLabel(stage.state)}</small></div>)}
              </div>
            </section>

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
              {selectedEvents.map(item => <div className={`report-event event-${visualFromStatus(item.status)}`} key={item.id}>
                <i className={visualFromStatus(item.status)}/><div><div><strong>{titleCase(item.agent_name)}</strong><time>{new Date(item.created_at).toLocaleTimeString()}</time></div><p>{item.message}</p></div>
              </div>)}
              {selectedEvents.length === 0 && <Empty label="No timeline events recorded for this incident."/>}
            </div>
          </section>}

          {detailTab === 'report' && <>
            <section className="report-hero">
              <div className="report-icon"><FileText size={22}/></div>
              <div><span>POST-INCIDENT REPORT</span><h3>{terminalStatuses.has(selected.status) ? 'Intervention summary ready' : 'Report building live'}</h3><p>The report contains diagnosis, policy decision, remediation result and the complete agent timeline.</p></div>
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

function Metric({icon,label,value,sub,tone}:{icon:React.ReactNode,label:string,value:number,sub:string,tone:'active'|'success'|'warning'|'info'|'neutral'}) {
  return <article className={`metric-card metric-${tone}`}><div className="metric-icon">{icon}</div><div><span>{label}</span><strong>{value}</strong><small>{sub}</small></div></article>
}

function PipelineCard({stage,index}:{stage:PipelineStage,index:number}) {
  const Icon = stage.icon
  return <article className={`pipeline-stage ${stage.state}`}>
    <div className="stage-index">{String(index + 1).padStart(2, '0')}</div>
    <div className="stage-icon"><Icon size={18}/></div>
    <div className="stage-copy">
      <div><h3>{stage.label}</h3><span className={`stage-state ${stage.state}`}><i/>{visualLabel(stage.state)}</span></div>
      <p>{stage.message}</p>
      <small>{stage.time ? timeAgo(stage.time) : 'Waiting'}</small>
    </div>
  </article>
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
