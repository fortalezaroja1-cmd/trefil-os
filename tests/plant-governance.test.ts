import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";

test("Producción y gobierno comparten casos, conservan versiones y autorizan cada operación en servidor", async () => {
  const db = new PGlite();
  const creator = randomUUID(),
    maker = randomUUID(),
    receiver = randomUUID(),
    manager = randomUUID();
  try {
    await db.exec(`create role authenticated;create role anon;create schema workforce;
 create table workforce.people(id uuid primary key,full_name text,active boolean default true,removed_at timestamptz,area text);
 create function workforce.require_person() returns workforce.people language plpgsql as $$
 declare p workforce.people;begin select * into strict p from workforce.people where id=current_setting('test.person')::uuid and active;return p;end $$;
 create function workforce.has_permission(workforce.people,text) returns boolean language sql as $$select $2 in ('inventory_register','inventory_approve')$$;
 create schema alegra;
 create table alegra.import_batches(id integer,status text,completed_at timestamptz);
 create table alegra.products(batch_id integer,source_code text,reference text,name text,unit text);`);
    for (const migration of [
      "20261123214937_central_inventory_ledger",
      "20261123222132_central_inventory_available_presentations",
    ]) {
      await db.exec(
        await readFile(
          new URL(
            "../supabase/migrations/" + migration + ".sql",
            import.meta.url,
          ),
          "utf8",
        ),
      );
    }
    await db.exec(
      "insert into inventory_hub.items values ('TEST','Producto','m'),('COBRE','Cobre','kg')",
    );
    await db.exec(
      await readFile(
        new URL(
          "../supabase/migrations/20261124141518_plant_governance.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    for (const id of [creator, maker, receiver, manager])
      await db.query(
        "insert into workforce.people(id,full_name) values($1,'Persona de prueba')",
        [id],
      );
    await db.query(
      "insert into plant_ops.access(person,profile) values($1,'CREADOR')",
      [creator],
    );
    async function login(id: string) {
      await db.query("select set_config('test.person',$1,false)", [id]);
      await db.exec("set role authenticated");
    }
    async function cmd(
      area: string,
      action: string,
      id: string,
      body: unknown,
      version = 0,
      request = randomUUID(),
    ) {
      return db.query(
        "select public.plant_command($1,$2,$3,$4,$5::jsonb,'Soporte de prueba',$6)",
        [area, action, id, version, JSON.stringify(body), request],
      );
    }
    await db.exec(
      await readFile(
        new URL(
          "../supabase/migrations/20261124143551_plant_materials_and_prices.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    await login(creator);
    await db.exec(
      "select public.central_inventory_record('TEST','PLANTA','conteo',0,'APERTURA',0,gen_random_uuid()),public.central_inventory_record('COBRE','MATERIA PRIMA','conteo',5,'APERTURA',0,gen_random_uuid())",
    );
    for (const [vigente, precio] of [
      ["2000-01-01", 10],
      ["2001-01-01", 12],
      ["2200-01-01", 15],
    ]) {
      await cmd("produccion", "crear", randomUUID(), {
        tipo: "precio",
        titulo: "Tarifa",
        lista: "General",
        codigo: "TEST",
        vigente,
        precio,
      });
    }
    const prices = await db.query<{ p: { precio: string }[] }>(
      "select public.plant_current_prices() p",
    );
    assert.deepEqual(
      prices.rows[0].p.map((p) => Number(p.precio)),
      [12],
    );
    for (const [id, perfil, permisos] of [
      [
        maker,
        "PRODUCCIÓN",
        ["planta.ver", "planta.registrar", "planta.verificar"],
      ],
      [receiver, "BODEGA", ["planta.ver", "bodega.recibir"]],
      [
        manager,
        "GERENTE",
        [
          "control.ver",
          "control.seguimiento",
          "control.aprobar",
          "archivo.ver",
        ],
      ],
    ]) {
      await cmd("control", "acceso", String(id), { perfil, permisos });
    }
    const file = randomUUID();
    await cmd("control", "crear", file, {
      tipo: "expediente",
      titulo: "Reservado",
      asunto: "Prueba",
      nivel: "CREADOR",
      fecha: "2026-11-24",
      responsable: "Archivo",
      archivo: "JVBERi0x",
    });
    await login(manager);
    assert.ok(
      !JSON.stringify(
        (await db.query("select public.plant_workspace('control')")).rows,
      ).includes(file),
    );
    await assert.rejects(db.query("select public.plant_file($1,1)", [file]));
    await login(maker);
    await assert.rejects(db.query("select public.plant_workspace('control')"));
    await assert.rejects(db.query("select * from plant_ops.records"));
    const ficha = randomUUID(),
      ot = randomUUID(),
      delivery = randomUUID();
    await cmd("produccion", "crear", ficha, {
      tipo: "ficha",
      titulo: "Alambre",
      codigo: "TEST",
      unidad: "m",
      presentacion: "carreta",
      materiales: "cobre",
      ruta: "Recuperación\nEmpaque",
      formula: [{ codigo: "COBRE", cantidad: 2, costo: 5, unidad: "kg" }],
    });
    const order = {
      tipo: "ot",
      titulo: "Reunión",
      acta: "Acta",
      lineas: [
        {
          ficha,
          cantidad: 3,
          fecha: "2026-11-25",
          responsable: "Planta",
          prioridad: "Media",
        },
      ],
    };
    await cmd("produccion", "crear", ot, order);
    await assert.rejects(cmd("produccion", "crear", randomUUID(), order));
    const batch = randomUUID();
    const lot = {
      tipo: "entrega",
      titulo: "Parcial",
      padre: ot,
      ficha,
      lote: batch,
      cantidad: 2,
      bodega: "PLANTA",
      soporte: "Entrega",
    };
    await assert.rejects(cmd("produccion", "crear", delivery, lot));
    await cmd(
      "produccion",
      "verificar",
      ot,
      { ficha, ruta: "Recuperación\nEmpaque" },
      1,
    );
    await cmd("produccion", "crear", batch, {
      tipo: "lote",
      titulo: "Lote",
      padre: ot,
      ficha,
      soporte: "Verificación",
    });
    await cmd("produccion", "crear", delivery, lot);
    await assert.rejects(
      cmd("produccion", "recibir", delivery, { recibido: 2 }, 1),
    );
    await login(receiver);
    await cmd("produccion", "recibir", delivery, { recibido: 1 }, 1);
    const key = randomUUID();
    await cmd("produccion", "recibir", delivery, { recibido: 2 }, 2, key);
    await cmd("produccion", "recibir", delivery, { recibido: 2 }, 2, key);
    await login(manager);
    const snapshot = (
      await db.query<{
        plant_workspace: {
          registros: { id: string; parent: string; kind: string }[];
        };
      }>("select public.plant_workspace('control')")
    ).rows[0].plant_workspace;
    const incident = snapshot.registros.find(
      (r) => r.kind === "caso" && r.parent === delivery,
    );
    assert.ok(incident);
    await cmd("control", "aprobar", incident.id, {}, 1);
    await login(maker);
    await cmd("produccion", "cerrar", batch, {}, 1);
    await assert.rejects(cmd("produccion", "cerrar", ot, { faltantes: {} }, 2));
    await cmd(
      "produccion",
      "cerrar",
      ot,
      {
        faltantes: { [ficha]: "Falta material" },
        consumos: { '["COBRE", "kg", "MATERIA PRIMA"]': 4 },
      },
      2,
    );
    await assert.rejects(cmd("produccion", "reabrir", ot, {}, 3));
    await login(creator);
    await cmd("produccion", "reabrir", ot, {}, 3);
    const spool = randomUUID(),
      op = randomUUID(),
      cut = randomUUID();
    await cmd("produccion", "crear", spool, {
      tipo: "carreta",
      titulo: "Carreta de ensayo",
      padre: delivery,
      metros: 2,
    });
    const cutBody = {
      tipo: "corte",
      titulo: "Primer corte",
      padre: spool,
      pedido: op,
      metros: 2,
      soporte: "Orden firmada",
    };
    await assert.rejects(cmd("produccion", "crear", cut, cutBody));
    await cmd("produccion", "crear", op, {
      tipo: "pedido_corte",
      titulo: "OP institucional",
      op: "OP-PRUEBA",
      codigo: "TEST",
      metros: 2,
      soporte: "Confirmación de Ventas",
    });
    await cmd("produccion", "crear", cut, cutBody);
    await assert.rejects(cmd("produccion", "crear", randomUUID(), cutBody));
    await cmd("produccion", "despachar", cut, { real: 2 }, 1);
    await cmd("produccion", "cerrar", spool, { saldo: 0 }, 1);
    await db.exec("reset role");
    assert.equal(
      Number(
        (
          await db.query<{ physical: number }>(
            "select physical from inventory_hub.balances where code='TEST'",
          )
        ).rows[0].physical,
      ),
      0,
    );
    const material = await db.query<{ physical: number; reserved: number }>(
      "select physical,reserved from inventory_hub.balances where code='COBRE'",
    );
    assert.equal(Number(material.rows[0].physical), 1);
    assert.equal(Number(material.rows[0].reserved), 1);
    await db.query("update workforce.people set active=false where id=$1", [
      manager,
    ]);
    await login(manager);
    await assert.rejects(db.query("select public.plant_workspace('control')"));
  } finally {
    await db.close();
  }
});
