create table
items (
    id uuid not null,
    user_id uuid not null references auth.users (id) on delete cascade,
    updated_at timestamptz not null,
    deleted boolean not null,
    name text not null,
    primary key (id, user_id)
);

create trigger handle_conflicts
before update on items
for each row
execute function discard_older_updates();

alter publication supabase_realtime add table items;

alter table items enable row level security;

create policy "Users can work with own data"  -- noqa
on public.items
for all
using (
    (auth.uid() = user_id)
);
