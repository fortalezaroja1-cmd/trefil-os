import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
import type { WorkforceDay } from "../src/lib/workforce";

const uuid = (suffix: number) =>
  "d0000000-0000-4000-8000-" + String(suffix).padStart(12, "0");

test("Equipo unifica usuario, permisos individuales y horario", async () => {
  const db = new PGlite();
  const authAdmin = uuid(1);
  const authAgent = uuid(2);
  const admin = uuid(11);
  const agent = uuid(12);
  try {
    await db.exec(`
      create schema auth;
      create role anon;
      create role authenticated;
      create role service_role;
      create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
      $$;
      create function auth.jwt() returns jsonb language sql stable as $$
        select jsonb_build_object('aal',current_setting('request.jwt.claim.aal',true))
      $$;
      grant usage on schema auth to anon,authenticated,service_role;
    `);
    for (const migration of [
      "20261111140836_workforce.sql",
      "20261111144203_cedula_identity.sql",
      "20261111153246_workforce_roles_permissions.sql",
      "20261111164415_developer_mcp_access.sql",
      "20261117135745_workforce_member_profiles.sql",
      "20261117144544_simplify_team_admin_access.sql",
    ]) {
      await db.exec(await readFile(new URL(`../supabase/migrations/${migration}`, import.meta.url), "utf8"));
    }
    await db.query("insert into auth.users values($1,$2,now()),($3,$4,now())", [
      authAdmin, `${"a".repeat(64)}@identidad.trefielectric.internal`,
      authAgent, `${"b".repeat(64)}@identidad.trefielectric.internal`,
    ]);
    await db.query(`
      insert into workforce.people(id,user_id,identifier_hash,identifier_last_four,full_name,job_title,area,access_role)
      values($1,$2,$3,'1111','Federico Administrador','Administrador general','Administración','admin'),
            ($4,$5,$6,'2222','Usuario Operativo','Auxiliar','Operaciones','employee')
    `, [admin, authAdmin, "a".repeat(64), agent, authAgent, "b".repeat(64)]);

    await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.aal','aal1',false)", [authAdmin]);
    await db.exec("set role authenticated");
    const first = (await db.query<{ data: WorkforceDay }>("select public.workforce_day(null) data")).rows[0].data;
    assert.equal(first.roles.find((role) => role.code === "admin")?.name, "Administrador total");
    assert.equal(first.can_manage, true);
    assert.ok(first.roles.some((role) => role.code === "reader"));
    assert.ok(first.permissions.some((permission) => permission.module === "cash"));

    await db.query("select public.workforce_save_member_access($1,$2,$3,$4)", [
      agent,
      "usuario@trefielectric.com",
      "reader",
      ["tasks_view_own", "cash_view", "reports_view"],
    ]);
    await db.query("select public.workforce_save_availability($1,$2::jsonb)", [
      agent,
      JSON.stringify([
        { weekday: 1, start_time: "08:00", end_time: "17:00", slot_order: 0, active: true },
        { weekday: 2, start_time: "09:00", end_time: "18:00", slot_order: 0, active: true },
      ]),
    ]);
    const updated = (await db.query<{ data: WorkforceDay }>("select public.workforce_day(null) data")).rows[0].data;
    const member = updated.people.find((person) => person.id === agent);
    assert.equal(member?.email, "usuario@trefielectric.com");
    assert.deepEqual(member?.permissions, ["tasks_view_own", "cash_view", "reports_view"]);
    assert.equal(member?.availability?.length, 2);
    assert.equal(member?.availability?.[0].start_time, "08:00");

    await db.query("select set_config('request.jwt.claim.sub',$1,false)", [authAgent]);
    const agentView = (await db.query<{ data: WorkforceDay }>("select public.workforce_day(null) data")).rows[0].data;
    assert.deepEqual(agentView.capabilities, ["tasks_view_own", "cash_view", "reports_view"]);
    await assert.rejects(
      db.query("select public.workforce_mark_shift('arrival',$1)", [uuid(30)]),
      /no permite registrar asistencia/,
    );
  } finally {
    await db.close();
  }
});
