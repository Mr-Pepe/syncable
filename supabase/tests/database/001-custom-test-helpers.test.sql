/**
    * ### tests.delete_supabase_user(identifier text)
    *
    * Deletes a user from the `auth.users` table.
    *
    * Parameters:
    * - `identifier` - The user to delete.
    *
    * Example:
    * ```sql
    *   SELECT tests.create_supabase_user('test_owner');
    *   SELECT tests.delete_supabase_user('test_owner');
    * ```
 */

create or replace function tests.delete_supabase_user(identifier text)
returns void
security definer
set search_path = auth, pg_temp
as $$
BEGIN
    DELETE FROM auth.users
    WHERE raw_user_meta_data ->> 'test_identifier' = identifier;
END;
$$ language plpgsql;

-- Verify setup with a no-op test
begin;
select plan(1);
select ok(true, 'Custom test helpers are set up');
select * from finish(); --noqa
rollback;
