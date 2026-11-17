import { useEffect, useMemo, useState, type FormEvent } from "react";
import {
  CalendarClock,
  Check,
  ChevronDown,
  ChevronRight,
  ClipboardList,
  Clock3,
  Copy,
  MoreHorizontal,
  Plus,
  ShieldCheck,
  UserPlus,
  Users,
  X,
} from "lucide-react";
import {
  documentIdentity,
  roleLabel,
  workforceRpc,
  WorkforceError,
  type AvailabilityInterval,
  type DirectoryPerson,
  type PermissionCode,
  type PermissionDefinition,
  type RoleDefinition,
  type WorkforceDay,
} from "@/lib/workforce";
import { Field } from "./ui";
import type { Perform } from "./workforce-app";

const dayNames = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];
const moduleNames: Record<string, string> = {
  personal: "Mi jornada",
  workforce: "Equipo y tareas",
  finance: "Finanzas",
  cash: "Caja",
  inventory: "Inventarios",
  sales: "Ventas",
  debts: "Deudas",
  agenda: "Agenda financiera",
  reports: "Informes",
  documents: "Documentos",
  integrations: "Integraciones e IA",
  administration: "Administración",
};

function defaultAvailability(): AvailabilityInterval[] {
  return dayNames.map((_, index) => ({
    weekday: index + 1,
    start_time: index < 6 ? "09:00" : "09:00",
    end_time: index < 6 ? "18:00" : "18:00",
    slot_order: 0,
    active: index < 6,
  }));
}

function initials(name: string) {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
}

function effectivePermissions(person: DirectoryPerson, roles: RoleDefinition[]) {
  return person.permissions ?? roles.find((role) => role.code === person.access_role)?.permissions ?? [];
}

export function WorkforceMemberConsole({
  snapshot,
  busy,
  perform,
}: {
  snapshot: WorkforceDay;
  busy: boolean;
  perform: Perform;
}) {
  const [selectedId, setSelectedId] = useState(snapshot.me.id);
  const [drawer, setDrawer] = useState<DirectoryPerson | "new" | null>(null);
  const [invite, setInvite] = useState<{ name: string; link: string } | null>(null);
  const people = snapshot.people;
  const selected = people.find((person) => person.id === selectedId) ?? people[0];

  useEffect(() => {
    if (!people.some((person) => person.id === selectedId) && people[0]) {
      setSelectedId(people[0].id);
    }
  }, [people, selectedId]);

  if (!selected) {
    return (
      <section className="member-empty">
        <Users size={28} />
        <h2>Crea la primera persona del equipo</h2>
        <button className="button button-primary" onClick={() => setDrawer("new")}>
          <UserPlus size={17} /> Crear usuario
        </button>
      </section>
    );
  }

  return (
    <section className="member-console">
      <header className="member-console-heading">
        <div>
          <p className="workforce-eyebrow">ADMINISTRACIÓN</p>
          <h2>Equipo y permisos</h2>
          <p>Crea usuarios, define sus funciones y programa su jornada desde un solo lugar.</p>
        </div>
        <button className="button button-primary" disabled={busy} onClick={() => setDrawer("new")}>
          <UserPlus size={17} /> Crear usuario
        </button>
      </header>

      <div className="member-console-grid">
        <aside className="member-directory" aria-label="Miembros del equipo">
          <div className="member-directory-title">
            <strong>Miembros</strong>
            <span>{people.length}</span>
          </div>
          <ul>
            {people.map((person) => {
              const self = person.id === snapshot.me.id;
              const administrator = person.access_role === "admin";
              return (
                <li key={person.id}>
                  <button
                    className={person.id === selected.id ? "selected" : ""}
                    onClick={() => setSelectedId(person.id)}
                  >
                    <span className="member-avatar">{initials(person.full_name)}</span>
                    <span className="member-summary">
                      <strong>
                        {person.full_name}
                        {self && <small>Tú</small>}
                      </strong>
                      <span>{person.email || `${person.job_title} · ${person.area}`}</span>
                      <span className={administrator ? "member-admin-role" : ""}>
                        {administrator ? "Administrador total" : roleLabel(snapshot.roles, person.access_role)}
                      </span>
                    </span>
                    <MoreHorizontal size={17} aria-hidden="true" />
                  </button>
                </li>
              );
            })}
          </ul>
        </aside>

        <div className="member-detail">
          <MemberDetailHeader
            person={selected}
            roles={snapshot.roles}
            permissions={snapshot.permissions}
            self={selected.id === snapshot.me.id}
            busy={busy}
            edit={() => setDrawer(selected)}
          />
          <AvailabilityEditor person={selected} busy={busy} perform={perform} />
          <section className="member-tasks-panel">
            <div>
              <ClipboardList size={19} />
              <div>
                <h3>Tareas programadas</h3>
                <p>Actividades asignadas para {snapshot.day === snapshot.today ? "hoy" : snapshot.day}.</p>
              </div>
            </div>
            <span>
              {snapshot.tasks.filter((task) => task.person_id === selected.id && task.status !== "cancelled").length} tareas
            </span>
          </section>
        </div>
      </div>

      {drawer && (
        <MemberDrawer
          key={drawer === "new" ? "new" : drawer.id}
          person={drawer === "new" ? undefined : drawer}
          snapshot={snapshot}
          busy={busy}
          perform={perform}
          close={() => setDrawer(null)}
          invited={(name, link) => {
            setDrawer(null);
            setInvite({ name, link });
          }}
        />
      )}
      {invite && <InviteResult invite={invite} close={() => setInvite(null)} />}
    </section>
  );
}

function MemberDetailHeader({
  person,
  roles,
  permissions,
  self,
  busy,
  edit,
}: {
  person: DirectoryPerson;
  roles: RoleDefinition[];
  permissions: PermissionDefinition[];
  self: boolean;
  busy: boolean;
  edit: () => void;
}) {
  const granted = effectivePermissions(person, roles);
  const modules = new Set(
    permissions.filter((permission) => granted.includes(permission.code)).map((permission) => permission.module ?? permission.category),
  );
  return (
    <section className="member-profile-header">
      <div>
        <span className="member-avatar large">{initials(person.full_name)}</span>
        <div>
          <div className="member-profile-name">
            <h3>{person.full_name}</h3>
            {self && <span>Tú</span>}
          </div>
          <p>{person.job_title} · {person.area}</p>
          <div className="member-profile-badges">
            <span className={person.access_role === "admin" ? "total" : ""}>
              <ShieldCheck size={14} />
              {person.access_role === "admin" ? "Administrador total" : roleLabel(roles, person.access_role)}
            </span>
            <span>{modules.size || granted.length} módulos autorizados</span>
            <span>{person.active ? "Usuario activo" : "Usuario inactivo"}</span>
          </div>
        </div>
      </div>
      <button className="button button-secondary" disabled={busy} onClick={edit}>
        {person.access_role === "admin" && self ? "Revisar control total" : "Editar usuario"}
      </button>
    </section>
  );
}

function AvailabilityEditor({ person, busy, perform }: { person: DirectoryPerson; busy: boolean; perform: Perform }) {
  const [rows, setRows] = useState<AvailabilityInterval[]>(person.availability?.length ? person.availability : defaultAvailability());

  useEffect(() => {
    setRows(person.availability?.length ? person.availability : defaultAvailability());
  }, [person.id, person.availability]);

  function update(index: number, change: Partial<AvailabilityInterval>) {
    setRows((current) => current.map((row, rowIndex) => rowIndex === index ? { ...row, ...change } : row));
  }

  function addSlot(weekday: number) {
    setRows((current) => [
      ...current,
      { weekday, start_time: "13:00", end_time: "17:00", slot_order: current.filter((row) => row.weekday === weekday).length, active: true },
    ].sort((a, b) => a.weekday - b.weekday || a.slot_order - b.slot_order));
  }

  function save() {
    void perform(
      (client) => workforceRpc(client, "workforce_save_availability", { p_person: person.id, p_schedule: rows }),
      `Horario de ${person.full_name} actualizado.`,
    );
  }

  return (
    <section className="member-schedule">
      <div className="member-section-heading">
        <div>
          <CalendarClock size={19} />
          <div><h3>Horario</h3><p>Disponibilidad semanal de {person.full_name}.</p></div>
        </div>
        <span className="member-status-dot">Disponible</span>
      </div>
      <div className="member-schedule-rows">
        {dayNames.map((name, dayIndex) => {
          const weekday = dayIndex + 1;
          const slots = rows.map((row, index) => ({ row, index })).filter(({ row }) => row.weekday === weekday);
          const enabled = slots.some(({ row }) => row.active);
          return (
            <div className="member-schedule-day" key={weekday}>
              <label className="member-day-toggle">
                <input
                  type="checkbox"
                  checked={enabled}
                  onChange={(event) => slots.forEach(({ index }) => update(index, { active: event.target.checked }))}
                />
                <span aria-hidden="true" />
                <strong>{name}</strong>
              </label>
              <div className="member-time-slots">
                {slots.map(({ row, index }) => (
                  <div className="member-time-slot" key={`${weekday}-${row.slot_order}`}>
                    <label><Clock3 size={15} /><input type="time" value={row.start_time.slice(0, 5)} disabled={!row.active} onChange={(event) => update(index, { start_time: event.target.value })} /></label>
                    <span>a</span>
                    <label><Clock3 size={15} /><input type="time" value={row.end_time.slice(0, 5)} disabled={!row.active} onChange={(event) => update(index, { end_time: event.target.value })} /></label>
                    {slots.length > 1 && <button type="button" aria-label="Eliminar intervalo" onClick={() => setRows((current) => current.filter((_, rowIndex) => rowIndex !== index))}><X size={16} /></button>}
                  </div>
                ))}
              </div>
              <button type="button" className="member-add-slot" aria-label={`Agregar intervalo el ${name}`} disabled={!enabled} onClick={() => addSlot(weekday)}><Plus size={18} /></button>
            </div>
          );
        })}
      </div>
      <div className="member-schedule-actions">
        <button className="button button-primary" disabled={busy} onClick={save}>Guardar horario</button>
      </div>
    </section>
  );
}

function MemberDrawer({
  person,
  snapshot,
  busy,
  perform,
  close,
  invited,
}: {
  person?: DirectoryPerson;
  snapshot: WorkforceDay;
  busy: boolean;
  perform: Perform;
  close: () => void;
  invited: (name: string, link: string) => void;
}) {
  const editingSelf = person?.id === snapshot.me.id;
  const [role, setRole] = useState(person?.access_role ?? "employee");
  const initial = useMemo(() => new Set(person ? effectivePermissions(person, snapshot.roles) : snapshot.roles.find((item) => item.code === "employee")?.permissions ?? []), [person, snapshot.roles]);
  const [granted, setGranted] = useState<Set<string>>(initial);
  const [expanded, setExpanded] = useState<string | null>(null);
  const groups = useMemo(() => {
    const result = new Map<string, PermissionDefinition[]>();
    for (const permission of snapshot.permissions) {
      const module = permission.module ?? permission.category;
      result.set(module, [...(result.get(module) ?? []), permission]);
    }
    return [...result.entries()];
  }, [snapshot.permissions]);

  function selectRole(code: string) {
    setRole(code);
    setGranted(new Set(snapshot.roles.find((item) => item.code === code)?.permissions ?? []));
  }

  function toggleModule(modulePermissions: PermissionDefinition[]) {
    setGranted((current) => {
      const next = new Set(current);
      const all = modulePermissions.every((permission) => next.has(permission.code));
      modulePermissions.forEach((permission) => all ? next.delete(permission.code) : next.add(permission.code));
      return next;
    });
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const fields = new FormData(event.currentTarget);
    const name = String(fields.get("name") ?? "").trim();
    const personId = person?.id ?? crypto.randomUUID();
    void perform(async (client) => {
      const documentNumber = String(fields.get("document") ?? "");
      const identity = documentNumber
        ? await documentIdentity(documentNumber)
        : person?.identifier_hash && person.identifier_last_four
          ? { hash: person.identifier_hash, lastFour: person.identifier_last_four }
          : null;
      if (!identity) throw new WorkforceError("Introduce el número de cédula de la persona.");
      await workforceRpc(client, "workforce_save_person", {
        p_id: personId,
        p_identifier_hash: identity.hash,
        p_identifier_last_four: identity.lastFour,
        p_name: name,
        p_title: fields.get("title"),
        p_area: fields.get("area"),
        p_role: editingSelf ? person?.access_role : role,
        p_supervisor: null,
        p_active: editingSelf || fields.get("active") === "on",
      });
      await workforceRpc(client, "workforce_save_member_access", {
        p_person: personId,
        p_email: fields.get("email") || null,
        p_role: editingSelf ? person?.access_role : role,
        p_permissions: editingSelf ? effectivePermissions(person!, snapshot.roles) : [...granted],
      });
      if (!person) {
        const { data, error } = await client.functions.invoke<{ link: string }>("workforce-invite", { body: { action: "link", personId } });
        if (error || !data?.link) throw new WorkforceError("El usuario se creó, pero no pudimos generar su enlace de activación.");
        invited(name, data.link);
      } else {
        close();
      }
    }, person ? "Usuario y permisos actualizados." : "Usuario creado.");
  }

  return (
    <div className="member-drawer-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && close()}>
      <aside className="member-drawer" role="dialog" aria-modal="true" aria-labelledby="member-drawer-title">
        <header><div><p className="workforce-eyebrow">EQUIPO</p><h2 id="member-drawer-title">{person ? "Editar usuario" : "Crear usuario"}</h2></div><button className="icon-button" aria-label="Cerrar" onClick={close}><X size={20} /></button></header>
        <form onSubmit={submit}>
          <div className="member-form-grid">
            <Field label="Nombre completo"><input name="name" required minLength={2} maxLength={120} defaultValue={person?.full_name} /></Field>
            <Field label="Correo de trabajo"><input name="email" type="email" maxLength={254} defaultValue={person?.email ?? ""} placeholder="nombre@empresa.com" /></Field>
            <Field label="Número de cédula" hint={person ? "Déjalo vacío para conservar la cédula registrada." : "Será su usuario de ingreso; no se guardará el número completo."}><input name="document" inputMode="numeric" required={!person} disabled={person?.registered} /></Field>
            <Field label="Cargo"><input name="title" required minLength={2} maxLength={120} defaultValue={person?.job_title} /></Field>
            <Field label="Área"><input name="area" required minLength={2} maxLength={120} defaultValue={person?.area} /></Field>
          </div>

          <section className="member-role-section">
            <div><h3>Rol base</h3><p>Sirve como punto de partida; después puedes ajustar cada permiso.</p></div>
            <div className="member-role-options">
              {snapshot.roles.filter((item) => ["admin", "employee", "reader"].includes(item.code)).map((item) => (
                <button key={item.code} type="button" className={role === item.code ? "active" : ""} disabled={editingSelf} onClick={() => selectRole(item.code)}>
                  {item.code === "admin" ? "Administrador" : item.code === "employee" ? "Agente" : "Lector"}
                </button>
              ))}
            </div>
          </section>

          <section className="member-permission-section">
            <div className="member-permission-heading"><div><h3>Permisos por módulo</h3><p>Decide qué información puede ver y qué acciones puede ejecutar.</p></div><span>{granted.size}/{snapshot.permissions.length}</span></div>
            <div className="member-permission-list">
              {groups.map(([module, modulePermissions]) => {
                const count = modulePermissions.filter((permission) => granted.has(permission.code)).length;
                const all = count === modulePermissions.length;
                return (
                  <div className="member-permission-group" key={module}>
                    <div className="member-permission-row">
                      <button type="button" className="member-expand" onClick={() => setExpanded(expanded === module ? null : module)}>{expanded === module ? <ChevronDown size={17} /> : <ChevronRight size={17} />}</button>
                      <label><input type="checkbox" checked={all} disabled={editingSelf} onChange={() => toggleModule(modulePermissions)} /><span>{all && <Check size={13} />}</span><strong>{moduleNames[module] ?? module}</strong></label>
                      <small>{count}/{modulePermissions.length}</small>
                    </div>
                    {expanded === module && <div className="member-permission-items">{modulePermissions.map((permission) => <label key={permission.code}><input type="checkbox" checked={granted.has(permission.code)} disabled={editingSelf} onChange={() => setGranted((current) => { const next = new Set(current); next.has(permission.code) ? next.delete(permission.code) : next.add(permission.code); return next; })} /><span>{permission.name}<small>{permission.description}</small></span></label>)}</div>}
                  </div>
                );
              })}
            </div>
          </section>
          <label className="workforce-checkbox"><input name="active" type="checkbox" defaultChecked={person?.active ?? true} disabled={editingSelf} /> Usuario activo</label>
          {editingSelf && <p className="member-protected"><ShieldCheck size={16} /> Tu cuenta conserva control total para evitar que la empresa quede sin administración.</p>}
          <footer><button type="button" className="button button-secondary" onClick={close} disabled={busy}>Cancelar</button><button type="submit" className="button button-primary" disabled={busy}>{person ? "Guardar cambios" : "Crear y generar acceso"}</button></footer>
        </form>
      </aside>
    </div>
  );
}

function InviteResult({ invite, close }: { invite: { name: string; link: string }; close: () => void }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="member-drawer-backdrop">
      <section className="member-invite-result" role="dialog" aria-modal="true">
        <span className="member-success"><Check size={25} /></span>
        <h2>Usuario creado</h2>
        <p>{invite.name} ya aparece en el equipo. Comparte este enlace privado para que cree su contraseña.</p>
        <Field label="Enlace de activación"><input readOnly value={invite.link} onFocus={(event) => event.target.select()} /></Field>
        <button className="button button-primary" onClick={async () => { await navigator.clipboard.writeText(invite.link); setCopied(true); }}><Copy size={16} /> {copied ? "Enlace copiado" : "Copiar enlace"}</button>
        <button className="button button-secondary" onClick={close}>Cerrar</button>
      </section>
    </div>
  );
}
