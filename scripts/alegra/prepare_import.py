#!/usr/bin/env python3
"""Normalize Alegra exports and generate idempotent SQL seed chunks.

The generated files contain private company data and must stay outside Git.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

import openpyxl


BATCH_NAMESPACE = uuid.UUID("f27ccb13-6858-4ea9-9ad5-4f651da93dc0")


def clean(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def decimal_text(value: object) -> str | None:
    text = clean(value)
    if not text:
        return None
    if text in {"-", "—"}:
        return "0"
    text = re.sub(r"[^0-9,.-]", "", text)
    if "," in text and "." in text:
        if text.rfind(",") > text.rfind("."):
            text = text.replace(".", "").replace(",", ".")
        else:
            text = text.replace(",", "")
    elif "," in text:
        text = text.replace(".", "").replace(",", ".")
    elif text.count(".") > 1:
        text = text.replace(".", "")
    try:
        return format(Decimal(text), "f")
    except InvalidOperation as error:
        raise ValueError(f"Importe inválido: {value!r}") from error


def iso_date(value: object) -> str | None:
    text = clean(value)
    if not text:
        return None
    return datetime.strptime(text, "%d/%m/%Y").date().isoformat()


def row_key(row: dict[str, str], row_number: int) -> str:
    canonical = json.dumps({"row_number": row_number, "row": row}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def sql_literal(value: object) -> str:
    if value is None:
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


def json_literal(value: object) -> str:
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return sql_literal(encoded) + "::jsonb"


def read_contacts(path: Path) -> list[dict[str, object]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        rows = [{key: clean(value) for key, value in row.items()} for row in csv.DictReader(handle)]
    normalized = []
    for row_number, row in enumerate(rows, start=2):
        name = " ".join(filter(None, [row["Nombre"], row["Segundo nombre"], row["Primer apellido"], row["Segundo apellido"]]))
        normalized.append(
            {
                "source_key": row_key(row, row_number),
                "full_name": name,
                "identification": row["Identificación"] or None,
                "identification_type": row["Tipo de identificación"] or None,
                "check_digit": row["Dígito de verificación"] or None,
                "person_type": row["Tipo de persona"] or None,
                "tax_responsibility": row["Responsabilidad Tributaria"] or None,
                "department": row["Departamento"] or None,
                "municipality": row["Municipio"] or None,
                "address": row["Dirección"] or None,
                "postal_code": row["Código Postal"] or None,
                "country": row["País"] or None,
                "phone": row["Teléfono 1"] or None,
                "phone_2": row["Teléfono 2"] or None,
                "mobile": row["Celular"] or None,
                "email": (row["Correo"] or row["Correo electrónico 2"] or None),
                "email_2": row["Correo electrónico 2"] or None,
                "status": row["Estado del contacto"] or None,
                "receivable_account": row["Cuenta por cobrar"] or None,
                "payable_account": row["Cuenta por pagar"] or None,
                "payment_term": row["Término de pago"] or None,
                "price_list": row["Lista de precios"] or None,
                "salesperson": row["Vendedor"] or None,
                "raw_data": row,
            }
        )
    return normalized


def read_products(path: Path) -> list[dict[str, object]]:
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheet = workbook[workbook.sheetnames[0]]
    values = sheet.iter_rows(values_only=True)
    headers = [clean(value) for value in next(values)]
    rows = [{headers[index]: clean(value) for index, value in enumerate(row)} for row in values]
    normalized = []
    for row in rows:
        prices = {key.removeprefix("Precio: "): decimal_text(value) for key, value in row.items() if key.startswith("Precio: ") and clean(value)}
        quantities = {key.removeprefix("Cantidad en bodega "): decimal_text(value) for key, value in row.items() if key.startswith("Cantidad en bodega ") and clean(value)}
        normalized.append(
            {
                "source_code": row["Codigo"],
                "name": row["Nombre"],
                "reference": row["Referencia"] or None,
                "category": row["Categoria"] or None,
                "description": row["Descripcion"] or None,
                "tax_name": row["Nombre impuesto"] or None,
                "tax_percentage": decimal_text(row["Porcentaje impuesto"]),
                "tax_type": row["Tipo impuesto"] or None,
                "unit": row["Unidad de medida"] or None,
                "product_service_code": row["Codigo del producto o servicio"] or None,
                "allow_negative_sale": row["Venta en negativo"].lower() in {"si", "sí", "true", "1"},
                "unit_cost": decimal_text(row["Costo unitario"]),
                "barcode": row["Codigo de barras"] or None,
                "prices": prices,
                "warehouse_quantities": quantities,
                "raw_data": row,
            }
        )
    return normalized


def read_invoices(path: Path) -> list[dict[str, object]]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    normalized = []
    for row in rows:
        normalized.append(
            {
                "external_id": str(row["external_id"]),
                "number": clean(row["number"]),
                "customer": clean(row["customer"]),
                "issued_on": iso_date(row["issued_on"]),
                "due_on": iso_date(row["due_on"]),
                "total": decimal_text(row["total"]),
                "balance": decimal_text(row["balance"]),
                "status": clean(row["status"]),
                "raw_data": row,
            }
        )
    return normalized


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def chunks(rows: list[dict[str, object]], size: int) -> list[list[dict[str, object]]]:
    return [rows[index : index + size] for index in range(0, len(rows), size)]


def write_seed_chunk(path: Path, batch_id: uuid.UUID, kind: str, rows: list[dict[str, object]]) -> None:
    payload = json_literal(rows)
    sql = (
        "begin;\n"
        f"select private.import_alegra_rows('{batch_id}'::uuid,{sql_literal(kind)},{payload});\n"
        "commit;\n"
    )
    path.write_text(sql, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contacts", required=True, type=Path)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--invoices", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)

    contacts = read_contacts(arguments.contacts)
    products = read_products(arguments.products)
    invoices = read_invoices(arguments.invoices)
    if len(contacts) != 545 or len(products) != 317 or len(invoices) != 6881:
        raise RuntimeError("Los conteos de origen cambiaron; se detuvo la importación.")
    if len({row["source_key"] for row in contacts}) != len(contacts):
        raise RuntimeError("Hay filas de contacto exactamente duplicadas.")
    if len({row["source_code"] for row in products}) != len(products):
        raise RuntimeError("Hay códigos de producto duplicados.")
    if len({row["external_id"] for row in invoices}) != len(invoices):
        raise RuntimeError("Hay identificadores de factura duplicados.")

    digest = hashlib.sha256()
    for source in (arguments.contacts, arguments.products, arguments.invoices):
        digest.update(source.read_bytes())
    fingerprint = digest.hexdigest()
    batch_id = uuid.uuid5(BATCH_NAMESPACE, fingerprint)
    manifest = {
        "batch_id": str(batch_id),
        "fingerprint": fingerprint,
        "source": "Alegra Colombia",
        "prepared_at": datetime.now(timezone.utc).isoformat(),
        "counts": {"contacts": len(contacts), "products": len(products), "invoices": len(invoices)},
        "invoice_date_min": min(row["issued_on"] for row in invoices),
        "invoice_date_max": max(row["issued_on"] for row in invoices),
    }
    write_json(arguments.output / "manifest.json", manifest)
    write_json(arguments.output / "contacts.normalized.json", contacts)
    write_json(arguments.output / "products.normalized.json", products)
    write_json(arguments.output / "invoices.normalized.json", invoices)

    header_sql = (
        "begin;\n"
        "select private.begin_alegra_import("
        f"'{batch_id}'::uuid,{sql_literal(fingerprint)},{json_literal(manifest)});\n"
        "commit;\n"
    )
    (arguments.output / "000-begin.sql").write_text(header_sql, encoding="utf-8")
    sequence = 1
    for kind, rows, size in (("contacts", contacts, 200), ("products", products, 150), ("invoices", invoices, 300)):
        for part in chunks(rows, size):
            write_seed_chunk(arguments.output / f"{sequence:03d}-{kind}.sql", batch_id, kind, part)
            sequence += 1
    finish_sql = f"begin;\nselect private.finish_alegra_import('{batch_id}'::uuid);\ncommit;\n"
    (arguments.output / f"{sequence:03d}-finish.sql").write_text(finish_sql, encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
