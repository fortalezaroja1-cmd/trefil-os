import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";
import { pipeline } from "npm:@supabase/middleware@1";
import { withOAuthProtectedResource, withSupabase } from "npm:@supabase/server@1";

const clientOptions = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const protocolVersion = "2025-06-18";
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const timePattern = /^([01]\d|2[0-3]):[0-5]\d$/;
const oauthSecurity = [{ type: "oauth2", scopes: [] }];

const tools = [
  {
    name: "trefil_get_profile",
    description: "Identifica al usuario de Trefil OS conectado y enumera sus funciones autorizadas. No devuelve cédula ni credenciales.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    securitySchemes: oauthSecurity,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true },
    _meta: { "openai/profile": true },
  },
  {
    name: "trefil_system_status",
    description: "Consulta el estado del servidor MCP y los módulos institucionales conectados.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    securitySchemes: oauthSecurity,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true },
  },
  {
    name: "trefil_workforce_today",
    description: "Consulta la identidad laboral y las tareas de hoy de la persona conectada.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    securitySchemes: oauthSecurity,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true },
  },
  {
    name: "trefil_team_targets",
    description: "Lista las personas a quienes el usuario conectado puede programar tareas según su rol y permisos.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    securitySchemes: oauthSecurity,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true },
  },
  {
    name: "trefil_assign_task",
    description: "Programa una tarea para una persona autorizada del equipo. No cambia equipos, roles ni permisos.",
    inputSchema: {
      type: "object",
      properties: {
        personId: { type: "string", format: "uuid" },
        date: { type: "string", format: "date" },
        time: { type: "string", pattern: "^([01]\\d|2[0-3]):[0-5]\\d$" },
        title: { type: "string", minLength: 2, maxLength: 120 },
        details: { type: "string", maxLength: 1000 },
      },
      required: ["personId", "date", "title"], additionalProperties: false,
    },
    securitySchemes: oauthSecurity,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false, idempotentHint: false },
  },
] as const;

const staticScopeByTool: Record<string, string> = {
  trefil_system_status: "system.read",
  trefil_workforce_today: "workforce.read",
  trefil_team_targets: "workforce.tasks.write",
  trefil_assign_task: "workforce.tasks.write",
};

type Profile = {
  id: string;
  name: string;
  job_title: string;
  area: string;
  role: string;
  permissions: string[];
  tools: string[];
};

function secret(name: string) {
  const value = Deno.env.get(name);
  if (!value) return "";
  try {
    const parsed = JSON.parse(value);
    return typeof parsed === "string" ? parsed : parsed?.default ?? value;
  } catch { return value; }
}

function response(id: unknown, result?: unknown, error?: { code: number; message: string; data?: unknown }) {
  return Response.json(error ? { jsonrpc: "2.0", id: id ?? null, error } : { jsonrpc: "2.0", id: id ?? null, result }, {
    headers: { "Cache-Control": "no-store", "MCP-Protocol-Version": protocolVersion },
  });
}

async function sha256(value: string) {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function toolContent(value: unknown, isError = false) {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }], isError };
}

function validTaskArguments(args: Record<string, unknown>) {
  return uuidPattern.test(String(args.personId ?? ""))
    && datePattern.test(String(args.date ?? ""))
    && (!args.time || timePattern.test(String(args.time)))
    && typeof args.title === "string"
    && args.title.trim().length >= 2
    && args.title.trim().length <= 120
    && String(args.details ?? "").length <= 1000;
}

async function callOAuthTool(client: SupabaseClient, tool: string, args: Record<string, unknown>, profile: Profile) {
  if (tool === "trefil_get_profile") return toolContent({
    id: profile.id,
    name: profile.name,
    jobTitle: profile.job_title,
    area: profile.area,
    role: profile.role,
    permissions: profile.permissions,
  });
  if (tool === "trefil_system_status") return toolContent({
    server: "Trefil OS MCP", protocolVersion, authentication: "OAuth 2.1",
    permissionSource: "Equipo y permisos", connected: ["Equipo"],
    pendingAdapters: ["Finanzas", "Caja", "Inventarios", "Ventas", "Deudas", "Agenda financiera", "Informes", "Documentos"],
  });
  if (tool === "trefil_workforce_today") {
    const { data, error } = await client.rpc("developer_oauth_workforce_today");
    return error ? toolContent({ error: "No se pudo consultar Equipo." }, true) : toolContent(data);
  }
  if (tool === "trefil_team_targets") {
    const { data, error } = await client.rpc("developer_oauth_team_targets");
    return error ? toolContent({ error: "No se pudo consultar el equipo autorizado." }, true) : toolContent(data);
  }
  if (tool === "trefil_assign_task") {
    if (!validTaskArguments(args)) return toolContent({ error: "Parámetros de tarea inválidos." }, true);
    const taskId = crypto.randomUUID();
    const { error } = await client.rpc("developer_oauth_assign_task", {
      p_id: taskId, p_person: args.personId, p_day: args.date, p_time: args.time || null,
      p_title: args.title, p_details: args.details || "",
    });
    return error
      ? toolContent({ error: "El rol o los permisos de la cuenta no permiten programar esta tarea." }, true)
      : toolContent({ id: taskId, created: true });
  }
  return null;
}

async function handleOAuthMcp(request: Request, client: SupabaseClient) {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  let body: Record<string, any>;
  try { body = await request.json(); } catch { return response(null, undefined, { code: -32700, message: "Solicitud JSON inválida." }); }
  const method = typeof body?.method === "string" ? body.method : "unknown";
  const tool = method === "tools/call" && typeof body?.params?.name === "string" ? body.params.name : null;
  const { data, error } = await client.rpc("developer_oauth_profile");
  if (error || !data?.id) return response(body?.id, undefined, { code: -32001, message: "La cuenta no tiene acceso a asistentes de IA." });
  const profile = data as Profile;
  const allowed = new Set(profile.tools ?? []);
  if (method === "initialize") return response(body?.id, {
    protocolVersion, capabilities: { tools: { listChanged: false } }, serverInfo: { name: "Trefil OS", version: "1.1.0" },
  });
  if (method === "ping") return response(body?.id, {});
  if (method === "tools/list") return response(body?.id, { tools: tools.filter((item) => allowed.has(item.name)) });
  if (method === "tools/call" && tool) {
    if (!allowed.has(tool)) return response(body?.id, undefined, { code: -32003, message: "Tu rol no autoriza esta herramienta." });
    const result = await callOAuthTool(client, tool, body?.params?.arguments ?? {}, profile);
    return result ? response(body?.id, result) : response(body?.id, undefined, { code: -32601, message: "Herramienta no disponible." });
  }
  if (method.startsWith("notifications/")) return new Response(null, { status: 202 });
  return response(body?.id, undefined, { code: -32601, message: "Método no disponible." });
}

async function handleStaticMcp(request: Request, token: string) {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  const started = performance.now();
  let requestId = crypto.randomUUID();
  let keyId = "";
  let method = "unknown";
  let tool: string | null = null;
  try {
    const body = await request.json();
    method = typeof body?.method === "string" ? body.method : "unknown";
    tool = method === "tools/call" && typeof body?.params?.name === "string" ? body.params.name : null;
    const suppliedRequest = request.headers.get("X-Request-Id") ?? "";
    if (uuidPattern.test(suppliedRequest)) requestId = suppliedRequest;
    const url = secret("SUPABASE_URL");
    const serviceKey = secret("SUPABASE_SECRET_KEYS") || secret("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) throw new Error("server_not_configured");
    const admin = createClient(url, serviceKey, clientOptions);
    const { data: access, error: accessError } = await admin.rpc("developer_authorize_key", {
      p_hash: await sha256(token), p_method: method, p_tool: tool,
      p_origin: request.headers.get("Origin") ?? "", p_request: requestId,
    });
    if (accessError?.message.includes("rate_limited")) return response(body?.id, undefined, { code: -32029, message: "Límite de solicitudes alcanzado." });
    if (accessError || !access?.key_id) return response(body?.id, undefined, { code: -32001, message: "La clave no autoriza esta operación." });
    keyId = access.key_id;
    const scopes = new Set<string>(access.scopes ?? []);
    let result: unknown;
    if (method === "initialize") result = { protocolVersion, capabilities: { tools: { listChanged: false } }, serverInfo: { name: "Trefil OS", version: "1.1.0" } };
    else if (method === "ping") result = {};
    else if (method === "tools/list") result = { tools: tools.filter((item) => staticScopeByTool[item.name] && scopes.has(staticScopeByTool[item.name])) };
    else if (method === "tools/call") {
      const args = body?.params?.arguments ?? {};
      if (tool === "trefil_system_status") result = toolContent({ server: "Trefil OS MCP", protocolVersion, authentication: "access key", connected: ["Equipo"], scopes: [...scopes] });
      else if (tool === "trefil_workforce_today") {
        const { data, error } = await admin.rpc("developer_workforce_today", { p_key: keyId });
        result = error ? toolContent({ error: "No se pudo consultar Equipo." }, true) : toolContent(data);
      } else if (tool === "trefil_team_targets") {
        const { data, error } = await admin.rpc("developer_team_targets", { p_key: keyId });
        result = error ? toolContent({ error: "No se pudo consultar el equipo autorizado." }, true) : toolContent(data);
      } else if (tool === "trefil_assign_task") {
        if (!validTaskArguments(args)) result = toolContent({ error: "Parámetros de tarea inválidos." }, true);
        else {
          const taskId = crypto.randomUUID();
          const { error } = await admin.rpc("developer_assign_task", { p_key: keyId, p_id: taskId, p_person: args.personId, p_day: args.date, p_time: args.time || null, p_title: args.title, p_details: args.details || "" });
          result = error ? toolContent({ error: "El rol o el alcance de la clave no permite programar esta tarea." }, true) : toolContent({ id: taskId, created: true });
        }
      } else return response(body?.id, undefined, { code: -32601, message: "Herramienta no disponible." });
    } else if (method.startsWith("notifications/")) return new Response(null, { status: 202 });
    else return response(body?.id, undefined, { code: -32601, message: "Método no disponible." });
    await admin.rpc("developer_log_call", { p_key: keyId, p_request: requestId, p_method: method, p_tool: tool, p_outcome: "success", p_duration: Math.round(performance.now() - started) });
    return response(body?.id, result);
  } catch (error) {
    console.error("trefil-mcp-static", error instanceof Error ? error.message : "unknown");
    return response(null, undefined, { code: -32603, message: "Error interno del servidor MCP." });
  }
}

const oauthHandler = pipeline(
  // Publishes protected-resource metadata and the WWW-Authenticate discovery
  // challenge before the user-token gate, as required by OAuth-enabled MCP clients.
  [withOAuthProtectedResource(), withSupabase({ auth: "user" })],
  async (request, { supabase }) => handleOAuthMcp(request, supabase),
);

Deno.serve((request) => {
  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : (request.headers.get("X-Trefil-Access-Token") ?? "").trim();
  if (/^tos_[a-z0-9]{8}\.[A-Za-z0-9_-]{32,128}$/.test(token)) return handleStaticMcp(request, token);
  return oauthHandler(request);
});
