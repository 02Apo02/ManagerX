
-- ============================================================
-- Shared immutable-row protection
-- Used by immutable history/audit tables in later migrations.
-- ============================================================

create or replace function public.prevent_row_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception 'Table % is immutable; UPDATE/DELETE is not allowed',
        tg_table_name
        using errcode = 'restrict_violation';

    return old;
end;
$$;

revoke all
    on function public.prevent_row_mutation()
    from public, anon, authenticated;

