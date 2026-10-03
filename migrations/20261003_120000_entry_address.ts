import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-postgres'
import { ENTRIES_ADDRESS_UP, ENTRIES_ADDRESS_DOWN } from '../lib/market-ddl.ts'

// Адрес организации в справочнике — решение владельца 2026-10-03 (план обогащения, A0′).
// Текст DDL — lib/market-ddl.ts.

export async function up({ db }: MigrateUpArgs): Promise<void> {
  await db.execute(sql.raw(ENTRIES_ADDRESS_UP))
}

export async function down({ db }: MigrateDownArgs): Promise<void> {
  await db.execute(sql.raw(ENTRIES_ADDRESS_DOWN))
}
