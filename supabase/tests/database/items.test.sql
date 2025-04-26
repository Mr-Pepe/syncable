begin;

select plan(9);

select has_table('items', 'Items table exists');
select tests.rls_enabled('public', 'items');

select ok(
    exists (
        select 1
        from pg_publication_tables
        where
            pubname = 'supabase_realtime'
            and schemaname = 'public'
            and tablename = 'items'
    ),
    'Items table is added to supabase_realtime publication'
);

select tests.create_supabase_user('user1');
select tests.create_supabase_user('user2');

-- Create an item as user 1
select tests.authenticate_as('user1');

insert into items (
    id,
    user_id,
    updated_at,
    deleted,
    name
) values (
    gen_random_uuid(),
    tests.get_supabase_uid('user1'),
    now(),
    false,
    'User 1 Item'
);

select results_eq(
    'select count(*) from items',
    array[1::bigint],
    'User 1 only sees their own items'
);

select tests.authenticate_as('user2');
select results_eq(
    'select count(*) from items',
    array[0::bigint],
    'User 2 does not see User 1''s items'
);

select results_ne(
    $$ DELETE FROM items
       WHERE user_id = tests.get_supabase_uid('user1')
       RETURNING 1 $$,
    $$ VALUES (1) $$,
    'User 2 cannot delete User 1''s items'
);

-- Update item as user 1
select tests.authenticate_as('user1');

update items
set
    name = 'Updated item',
    updated_at = now() + interval '1 hour'
where
    user_id = tests.get_supabase_uid('user1');

select results_eq(
    'SELECT name FROM items WHERE user_id = tests.get_supabase_uid(''user1'')',
    array['Updated item'],
    'User 1 can update their own items'
);

-- Try updating item with an older timestamp
update items
set
    name = 'Older item',
    updated_at = now() - interval '1 hour'
where
    user_id = tests.get_supabase_uid('user1');

select results_eq(
    'SELECT name FROM items WHERE user_id = tests.get_supabase_uid(''user1'')',
    array['Updated item'],
    'Older updates are ignored'
);


select tests.delete_supabase_user('user1');

select results_eq(
    'SELECT count(*) FROM items',
    array[0::bigint],
    'Deleting a user deletes their items'
);

select * from finish(); --noqa
rollback;
