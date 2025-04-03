# Syncable

[![Pub](https://img.shields.io/pub/v/syncable.svg)](https://pub.dev/packages/syncable)
[![codecov](https://codecov.io/gh/Mr-Pepe/syncable/graph/badge.svg?token=BQQJDTOFZ0)](https://codecov.io/gh/Mr-Pepe/syncable)

Syncable is a library for offline-first multi-device data synchronization in Flutter apps.

It was initially developed for the [Chill Chinese app](https://chill-chinese.com/)
([iOS](https://apps.apple.com/us/app/id6742648707)/
[Android](https://play.google.com/store/apps/details?id=com.chillchinese.chill_chinese)/
[web](https://app.chill-chinese.com)).
As a result, it currently only works if you use a local [Drift](https://github.com/simolus3/drift/) database and a [Supabase](https://supabase.com/) backend.

The library provides a `SyncManager` class that handles data synchronization across devices.
Conflicts are resolved based on the last time an item was updated.
This means that if one item is modified offline on multiple devices, the version with
the newer timestamp overwrites the other one when the devices go online.

## Usage 📖

This section assumes that you already know how to work with Drift and Supabase.

Setting up syncing requires some work, but we will go through it step by step.

### Set up the local database 🗄️

Check out [the example database](test/utils/test_database.dart) for a complete code sample.

1. **Define a syncable:**
   Every item you want to synchronize must:

   - Implement the `Syncable` interface.
   - Have `fromJson`/`toJson` methods for (de-)serialization to/from the backend.
   - Have a `toCompanion` method that creates a Drift `UpdateCompanion` to write to the local database.
   - Be equatable.

2. **Define a syncable table:**
   Syncable items must be stored within a Drift `Table` that implements `SyncableTable`.

3. **Define a syncable database:**
   Syncable tables must be part of a `SyncableDatabase`.

### Set up the backend 🛠️

1. **Enable real-time:**
   The `SyncManager` must be able to establish a real-time connection to the backend to listen for changes.

   ```sql
   begin;
   drop publication if exists supabase_realtime;
   create publication supabase_realtime;
   commit;
   ```

2. **Create a function to reject old items:**
   The backend must resolve conflicts by rejecting items that have an older
   `updatedAt` timestamp than what is already in the backend database.

   ```sql
   create or replace function discard_older_updates()
   returns trigger as $$
   BEGIN
       IF NEW.updated_at <= OLD.updated_at THEN
           RETURN NULL; -- Discard the incoming row
       END IF;
       RETURN NEW; -- Allow the update to proceed
   END;
   $$ language plpgsql;
   ```

3. **Create a table to sync to:**
   Make sure to enable real-time and the conflict resolution function for your table.

   ```sql
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
   ```

### Start synchronization 🔄

1.  **Create a sync manager:**

    ```dart
    final syncManager = SyncManager(
      localDatabase: localDatabase,
      supabaseClient: supabaseClient,
    );
    ```

2.  **Register syncables:**

    ```dart
    syncManager.registerSyncable<Item>(
      backendTable: 'items',
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );
    ```

3.  **Set a user ID:**

    ```dart
    syncManager.setUserId(supabaseClient.auth.currentUser!.id);
    ```

    Syncing will only work if a user ID is set.
    See [below](#fill-user-id-after-registrationsign-in-) for how to handle
    scenarios where you initially don't have a user signed in.

4.  **Enable syncing:**

    ```dart
    syncManager.enableSync();
    ```

    Use `enableSync` and `disableSync` if you only want to enable syncing under
    certain conditions, e.g., if a Wi-Fi network is available or the user has
    subscribed to a paid plan.

The sync manager now does a couple of things in the background:

- It listens to changes to the local database for syncables you registered.
  Changes get added to a queue to be written to the backend.
- It listens to changes to the backend database for syncables you registered.
  Changes get added to a queue to be written to the local database.
- A loop running in the background checks for items in these queues and writes
  them to the backend or local database. Pass `syncInterval` to the sync manager
  to change the frequency at which this loop runs.
- A full sync between the local and backend databases is performed whenever
  the user changes or syncing gets enabled/disabled.
  See the [optimizations section](#optimizations) to reduce the number of full syncs.

> ⚠️ Don't forget to update the `updatedAt` timestamp whenever you change an item.
> Use UTC timestamps to make sure that synchronization works when users change time zones.

### Delete items 🗑️

Items should be soft-deleted to correctly propagate deletions across devices.
When deleting an item, set its `deleted` field to `true` and don't forget to
update its `updatedAt` field.

> ⚠️ Soft-deletion means that your client-side code needs to filter out deleted items.

### Fill user ID after registration/sign-in 👤

If a user creates items while not logged in, set the `userId` field to `null`.
Once the user signs in, call `fillMissingUserIdForLocalTables`.
It goes through the local tables for all registered syncables and sets the user
ID for all items that don't have a user ID yet.
If syncing is enabled, those items will then get synced to the backend automatically.

### Optimizations ⚡

There are a few mechanisms that can drastically reduce the ongoing data
usage for synchronization.

#### Only subscribe to backend if other devices are active

By default, the sync manager establishes a real-time subscription to the backend.
However, Supabase only allows a limited number of concurrent real-time connections to a database,
which can quickly become a problem if every active device is always listening to
changes in the backend.
Backend subscriptions should thus only be established if a user is simultaneously
online/active with more than one device.

One possible solution is to track device presence per user.
Whenever a device is online, it updates an entry in a backend table at certain intervals
(e.g., every minute).
All devices can then check if the user had any other recently active devices.

If you track device presence, you can tell the sync manager the last time that
another device was active via `setLastTimeOtherDeviceWasActive`.
The sync manager will only establish a real-time connection if a device was
recently active.
Set `otherDevicesConsideredInactiveAfter` when instantiating the sync manager to
adjust for how long devices should be considered active after their last ping.

#### Persistently store synchronization timestamps

By default, a full sync between local and backend tables is performed every time
syncing gets enabled, for example, after app startup.
This is very inefficient if only a few items changed since the last time a device was active.

To only sync incremental changes, provide a `SyncTimestampStorage` implementation to the sync manager.
A straightforward solution is to implement a class that uses
[SharedPreferences](https://pub.dev/packages/shared_preferences)
to persist sync timestamps across app restarts.

## Contributing 🤝

Want to work on the code? Keep reading.

### Set up a developer environment

Install:

- [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started)
- [just](https://github.com/casey/just)
- [sqlfluff](https://github.com/sqlfluff/sqlfluff) (requires Python)

All available tasks can be displayed by running `just`.

Install dependencies:

    just get-dependencies

### Generate code

Generate code whenever you change the interface of a class that is mocked
somewhere or needs to be serialized:

    just generate-code

Generated code must be checked into source control so that it doesn't have to
be rebuilt during every CI run.

### Local development

Start Supabase with:

    just start-supabase

To reset the database and reapply all migrations, run:

    supabase db reset

To stop Supabase:

    supabase stop

### Linting and testing

The following should always pass:

    just lint
    just test

### Conventional commits

This project uses [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/).

Available commit types can be found [in the changelog generator](tool/generate_changelog.dart).

### Cut a release

- Set the local main branch to the desired commit.
- Push the main branch!
- Run `dart run tool/generate_changelog.dart <lastVersion>` and prune output as desired.
- Run `gh release create` or create a new release on GitHub.
- Copy the changelog.
