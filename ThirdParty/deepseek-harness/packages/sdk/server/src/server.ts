/**
 * JSON-RPC methods and notifications for out-of-process harness SDKs.
 * The surrounding context owns plugins, persistence, and configured adapters.
 *
 * @module @deepseek-ai/dsh-sdk-jsonrpc-server/server
 */

import type { Context } from '@deepseek-ai/cordis'
import { randomUUID } from 'node:crypto'
import { resolve } from 'node:path'
import type { Agent, AgentHandle } from '@deepseek-ai/dsh-agent'
import type { ApprovalOutcome, ApprovalRequest } from '@deepseek-ai/dsh-user-approval'
import type { PreToolDecision, ToolExecution } from '@deepseek-ai/dsh-tools'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { carrierKeyOf, type Scoped } from '@deepseek-ai/dsh-scope'
import { SessionId, type SessionHeader } from '@deepseek-ai/dsh-session'
import type SubagentRuntime from '@deepseek-ai/dsh-subagent'
import type { SubagentRunEndInfo } from '@deepseek-ai/dsh-subagent'
import * as LlmDeepSeek from '@deepseek-ai/dsh-llm-deepseek'
import type {
  InitializeParams,
  InitializeResult,
  JsonRpcTransportPeer,
  SessionEventNotification,
  SessionPromptParams,
  SessionPromptResult,
  SubagentFinishedNotification,
  SubagentStartedNotification,
} from '@deepseek-ai/dsh-sdk-protocol'

interface SessionRecord {
  handle: AgentHandle
}

type DesktopPetApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'

/** Recover the delegating parent from the service-owned scoped carrier. */
function subagentParentOf(carrier: Scoped<SubagentRuntime>): Agent {
  return carrierKeyOf(carrier) as Agent
}

/** Deployment-specific status mapping for SDK turn and subagent outcomes. */
export interface HarnessSdkJsonRpcServerOptions {
  /** Report max-token termination as an accepted result instead of an infrastructure error. */
  maxTokensAsSuccess?: boolean
  /** Enable DesktopPet's fail-closed structured tool policy. */
  desktopPetPolicy?: boolean
}

export interface DesktopPetPluginSnapshot {
  /** Names registered in the live Harness tool registry after Cordis composition. */
  toolNames: string[]
  /** Skills discovered by the live provider for the initialized workspace. */
  skillNames: string[]
}

interface DesktopPetSkillSummary {
  name: string
  invocation: { modelInvocable: boolean }
}

const DESTRUCTIVE_COMMAND = /(^|[\s;&|])(rm|rmdir|unlink|shred|truncate|sudo|doas|osascript|launchctl|kill|pkill|diskutil|shutdown|reboot|mkfs|dd|printenv|env|set|export|declare)([\s;&|]|$)/i

export function desktopPetPreToolDecision(exec: ToolExecution, cwd: string): PreToolDecision | undefined {
  const args = exec.arguments as Record<string, unknown> | undefined
  const requestedSandbox = args?.sandbox_permissions
  if (requestedSandbox === 'workspace-write') {
    // DesktopPet already runs every tool under workspace-write. Models may
    // repeat the advertised retry fields after an earlier denial; normalize
    // that no-op request so it reaches the ordinary one-shot approval path.
    delete args?.sandbox_permissions
    delete args?.justification
  } else if (requestedSandbox !== undefined) {
    return { kind: 'deny', reason: 'DesktopPet policy blocks sandbox escalation.' }
  }
  if (exec.name.toLowerCase().includes('delete') || DESTRUCTIVE_COMMAND.test(String(args?.command ?? ''))) {
    return { kind: 'deny', reason: 'DesktopPet policy blocks destructive or privileged operations.' }
  }
  if (/deepseek_api_key|authorization\s*:/i.test(String(args?.command ?? ''))) {
    return { kind: 'deny', reason: 'DesktopPet policy blocks credential access.' }
  }

  const root = resolve(cwd)
  const outside = (value: string): boolean => {
    const path = resolve(root, value)
    return path !== root && !path.startsWith(`${root}/`)
  }
  const inspectPaths = (value: unknown, key = ''): boolean => {
    if (Array.isArray(value)) return value.some(item => inspectPaths(item, key))
    if (value !== null && typeof value === 'object') {
      return Object.entries(value).some(([childKey, child]) => inspectPaths(child, childKey))
    }
    if (typeof value !== 'string') return false
    const lowerKey = key.toLowerCase()
    return ['path', 'file', 'directory', 'cwd', 'target', 'destination', 'source', 'workdir']
      .some(name => lowerKey.includes(name)) && outside(value)
  }
  if (inspectPaths(exec.arguments)) {
    return { kind: 'deny', reason: 'DesktopPet policy blocks paths outside the selected workspace.' }
  }
  if (exec.name === 'bash') {
    const command = String(args?.command ?? '')
    if (/(^|\s)\.\.(?:\/|\s|$)|(^|\s)~\/|\$(?:\{HOME\}|HOME)/.test(command)
      || /(^|[\s'"=])\/(?!\/)/.test(command)) {
      return { kind: 'deny', reason: 'DesktopPet policy blocks shell paths outside the selected workspace.' }
    }
    return { kind: 'ask', reason: String(args?.description ?? 'Run a command in the selected workspace') }
  }
  if (exec.name === 'write' || exec.name === 'edit') {
    return { kind: 'ask', reason: `${exec.name} a file in the selected workspace` }
  }
  return undefined
}

function successStatus(reason: string, options: HarnessSdkJsonRpcServerOptions): 'ok' | 'error' {
  if (reason === 'completed') return 'ok'
  return reason === 'max-tokens' && options.maxTokensAsSuccess === true ? 'ok' : 'error'
}

/**
 * SDK server over one booted harness context and transport peer. Construction
 * subscribes to session, agent, and subagent lifecycle events until shutdown;
 * reinitialization is unsupported.
 */
export class HarnessSdkJsonRpcServer {
  private cwd = process.cwd()
  private provider = 'deepseek-official'
  private model = 'deepseek-official'
  private maxTokens: number | undefined
  private llmFiber: { dispose(): Promise<void> } | undefined
  private readonly sessions = new Map<string, SessionRecord>()
  private readonly sessionCreations = new Map<string, Promise<SessionRecord>>()
  private readonly disposers: (() => void)[] = []
  private shutdownTask: Promise<Record<string, never>> | undefined
  private shuttingDown = false

  constructor(
    private readonly ctx: Context,
    private readonly transport: JsonRpcTransportPeer,
    private readonly options: HarnessSdkJsonRpcServerOptions = {},
  ) {
    const serverOptions = this.options
    this.disposers.push(ctx.on('session/event', (session, event) => {
      const payload: SessionEventNotification = { sessionId: String(session.id), event }
      this.transport.notify('session.event', payload)
    }))
    this.disposers.push(ctx.on('agent/status', ({ agent, status }) => {
      this.transport.notify('session.status', { sessionId: String(agent.session.id), status })
    }))
    if (options.desktopPetPolicy === true) {
      this.disposers.push(ctx.on('tools/pre-execute', (exec: ToolExecution, next: () => Promise<PreToolDecision>) => {
        return Promise.resolve(desktopPetPreToolDecision(exec, this.cwd) ?? next())
      }, { prepend: true }))
    }
    this.disposers.push(ctx.on('approval/request', async (req: ApprovalRequest, next: () => Promise<ApprovalOutcome>) => {
      if (!this.sessions.has(String(req.agent.session.id))) return next()
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(new Error('DesktopPet approval timed out')), 120_000)
      const onAbort = (): void => controller.abort(req.signal?.reason ?? new Error('Approval cancelled'))
      req.signal?.addEventListener('abort', onAbort, { once: true })
      try {
        const result = await this.transport.request('desktopPet/approval.request', {
          requestId: randomUUID(),
          sessionId: String(req.agent.session.id),
          callId: req.callId === undefined ? undefined : String(req.callId),
          toolName: req.toolName,
          summary: req.reason ?? `Run ${req.toolName}`,
          risk: 'write-or-command',
          reason: req.reason,
        }, controller.signal) as { outcome?: DesktopPetApprovalOutcome }
        return result.outcome === 'allowed-once' || result.outcome === 'rejected'
          ? result.outcome
          : 'unavailable'
      } catch {
        return 'unavailable'
      } finally {
        clearTimeout(timer)
        req.signal?.removeEventListener('abort', onAbort)
      }
    }))
    this.disposers.push(ctx.on('session/created', (session) => {
      const parentSession = session.header.parentSession
      if (parentSession === undefined) return
      const payload: SubagentStartedNotification = {
        parentSessionId: String(parentSession),
        childSessionId: String(session.id),
      }
      this.transport.notify('subagent.started', payload)
    }))
    this.disposers.push(ctx.on('subagent/end', function (this: Scoped<SubagentRuntime>, info: SubagentRunEndInfo) {
      const parent = subagentParentOf(this)
      // This protocol reports only in-process child sessions. The service
      // snapshots the provider name and local flag through child disposal;
      // matching ids or parent lineage alone never establishes locality.
      if (!info.local) return
      const payload: SubagentFinishedNotification = {
        provider: info.provider,
        agentId: String(info.id),
        parentSessionId: String(parent.session.id),
        childSessionId: String(info.id),
        status: successStatus(info.stopReason, serverOptions),
        stopReason: info.stopReason,
        ...(info.lastAssistantMessage === undefined ? {} : { lastAssistantMessage: info.lastAssistantMessage }),
      }
      transport.notify('subagent.finished', payload)
    }))
  }

  /**
   * Configure the SDK route, mounting the DeepSeek fallback only when unowned.
   * @param params - SDK handshake parameters.
   * @returns server identity for the handshake.
   */
  async initialize(params: InitializeParams): Promise<InitializeResult> {
    if (params.maxTokens !== undefined
      && (!Number.isSafeInteger(params.maxTokens) || params.maxTokens <= 0)) {
      throw new TypeError('initialize maxTokens must be a positive safe integer')
    }
    this.cwd = resolve(params.cwd)
    this.provider = params.provider
    this.model = params.model
    this.maxTokens = params.maxTokens
    if (!this.hasAdapterFor(this.provider)) {
      if (this.provider !== 'deepseek-official') throw new Error(`no adapter registered for provider "${this.provider}"`)
      this.llmFiber = await this.ctx.plugin(LlmDeepSeek, {})
    }
    return { serverInfo: { name: 'deepseek-harness-sdk-runtime', version: '0.0.1' } }
  }

  /**
   * Queue one identified prompt without assigning later activity to it.
   * @param params - target session and user content.
   * @returns the durable message identity.
   */
  async prompt(params: SessionPromptParams): Promise<SessionPromptResult> {
    const rec = await this.getOrCreateSession(params.sessionId)
    // An agent-loop-only reload disposes the loop's agents while this record
    // survives; a retained agent accepts followup() silently, so validate the
    // record against the live registry before delivery (as the ACP bridge does).
    if (this.ctx.agents.get(rec.handle.agent.id) !== rec.handle.agent) {
      throw new Error(`session agent was disposed outside the server: ${params.sessionId}`)
    }
    const message = createUserMessage({ content: params.contentBlocks, source: { kind: 'user' } })
    rec.handle.agent.followup(message)
    return { messageId: message.id }
  }

  /**
   * Return the live model-tool registry used by DesktopPet's plugin settings.
   * The result comes from the booted Cordis tree rather than launch flags, so a
   * missing or failed plugin can never be reported as active merely because it
   * was requested in the environment.
   */
  async desktopPetPlugins(): Promise<DesktopPetPluginSnapshot> {
    if (this.options.desktopPetPolicy !== true) {
      throw new Error('desktopPet/plugins/list is unavailable outside a DesktopPet deployment')
    }
    const toolNames = (this.ctx.get('tools')?.schemas() ?? [])
      .map(tool => tool.name)
      .sort((left, right) => left.localeCompare(right))
    const skills = (await this.ctx.get('skills')?.list({ cwd: this.cwd }) ?? []) as DesktopPetSkillSummary[]
    const skillNames = skills
      .filter(skill => skill.invocation.modelInvocable)
      .map(skill => skill.name)
      .sort((left, right) => left.localeCompare(right))
    return { toolNames, skillNames }
  }

  /**
   * Dispose server-owned agents, adapter, and subscriptions to quiescence.
   * The surrounding context remains running.
   * @returns empty JSON-RPC result.
   */
  shutdown(): Promise<Record<string, never>> {
    this.shutdownTask ??= this.performShutdown()
    return this.shutdownTask
  }

  private async performShutdown(): Promise<Record<string, never>> {
    this.shuttingDown = true
    const pendingCreations = [...this.sessionCreations.values()]
    await Promise.allSettled(pendingCreations)
    this.sessionCreations.clear()
    const records = [...this.sessions.values()]
    this.sessions.clear()
    const failures: unknown[] = []
    while (this.disposers.length > 0) {
      try {
        this.disposers.pop()?.()
      } catch (error) {
        failures.push(error)
      }
    }
    const teardownResults = await Promise.allSettled([
      ...records.map(rec => Promise.resolve().then(() => rec.handle.dispose())),
      ...(this.llmFiber === undefined ? [] : [Promise.resolve().then(() => this.llmFiber?.dispose())]),
    ])
    this.llmFiber = undefined
    failures.push(...teardownResults
      .filter((result): result is PromiseRejectedResult => result.status === 'rejected')
      .map(result => result.reason as unknown))
    if (failures.length === 1) throw failures[0]
    if (failures.length > 1) throw new AggregateError(failures, 'SDK server teardown failed')
    return {}
  }

  /**
   * Dispatch one incoming JSON-RPC request to its typed handler. Throws (→ a
   * JSON-RPC error response) on an unknown method.
   * @param method - the JSON-RPC method name.
   * @param params - the raw params object from the wire.
   * @returns the handler's result, to be serialized as the response.
   */
  async handleRequest(method: string, params: Record<string, unknown> | undefined): Promise<unknown> {
    switch (method) {
      case 'initialize':
        return this.initialize(params as unknown as InitializeParams)
      case 'session/prompt':
        return this.prompt(params as unknown as SessionPromptParams)
      case 'desktopPet/plugins/list':
        return this.desktopPetPlugins()
      case 'shutdown':
        return this.shutdown()
      default:
        throw new Error(`unknown DeepSeek Harness SDK runtime method: ${method}`)
    }
  }

  private async getOrCreateSession(sessionId: string): Promise<SessionRecord> {
    if (this.shuttingDown) throw new Error('SDK server is shutting down')
    const existing = this.sessions.get(sessionId)
    if (existing) return existing
    const pending = this.sessionCreations.get(sessionId)
    if (pending) return pending
    const creation = this.createSession(sessionId)
    this.sessionCreations.set(sessionId, creation)
    void creation.then(
      () => { this.sessionCreations.delete(sessionId) },
      () => { this.sessionCreations.delete(sessionId) },
    )
    return creation
  }

  private async createSession(sessionId: string): Promise<SessionRecord> {
    // No preset composition: this server's compositions keep the model-facing
    // rows in the host plane, so this agent reads them from the global layer. A
    // deployment that configures a roster has to join one here first
    // (@deepseek-ai/dsh-agent-presets README, "Composing a child agent").
    const id = SessionId(sessionId)
    const agentOptions = {
      provider: this.provider,
      model: this.model,
      ...this.maxTokens === undefined ? {} : { maxTokens: this.maxTokens },
    }
    const persistence = this.ctx.get('sessionPersistence')
    const persisted = persistence === undefined
      ? undefined
      : (await persistence.list()).find((header: SessionHeader) => String(header.id) === sessionId)
    if (persisted?.cwd !== undefined && resolve(persisted.cwd) !== this.cwd) {
      throw new Error(
        `session "${sessionId}" belongs to a different cwd (persisted: ${persisted.cwd}, requested: ${this.cwd})`,
      )
    }
    const handle = persisted === undefined
      ? await this.ctx.agents.create({
          sessionId: id,
          meta: { cwd: this.cwd },
          agentOptions,
        })
      : await this.ctx.agents.resume({
          resumeSessionId: id,
          agentOptions,
        })
    const rec: SessionRecord = { handle }
    this.sessions.set(sessionId, rec)
    return rec
  }

  private hasAdapterFor(provider: string): boolean {
    return this.ctx.get('llm')?.listProviders().some(entry => entry.id === provider) ?? false
  }
}
