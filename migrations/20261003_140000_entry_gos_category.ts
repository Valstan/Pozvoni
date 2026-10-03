import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-postgres'
import { ENTRIES_GOS_UP, ENTRIES_GOS_DOWN } from '../lib/market-ddl.ts'

// Категория «Госучреждения» в enum entries.category — решение владельца 2026-10-03.
// Текст DDL — lib/market-ddl.ts.

export async function up({ db }: MigrateUpArgs): Promise<void> {
  await db.execute(sql.raw(ENTRIES_GOS_UP))
}

export async function down({ db }: MigrateDownArgs): Promise<void> {
  await db.execute(sql.raw(ENTRIES_GOS_DOWN))
}
