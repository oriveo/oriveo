# Account data isolation - test cases

---

## 1. partition.ts - partition manager

### 1.1 getActiveUID
| # | Scenario | Expected |
|---|------|------|
| 1 | meta DB empty (first launch) | returns `"guest"` |
| 2 | meta DB holds `"guest"` | returns `"guest"` |
| 3 | meta DB holds `"uid-abc"` | returns `"uid-abc"` |

### 1.2 setActiveUID
| # | Scenario | Expected |
|---|------|------|
| 1 | set to `"guest"`, then read | returns `"guest"` |
| 2 | set to `"uid-abc"`, then read | returns `"uid-abc"` |
| 3 | set to different values in a row | returns the last value set |

### 1.3 getDBName (pure function)
| # | Input | Expected output |
|---|------|----------|
| 1 | `"guest"` | `"oriveo--guest"` |
| 2 | `"abc123"` | `"oriveo--abc123"` |

### 1.4 getImageDBName (pure function)
| # | Input | Expected output |
|---|------|----------|
| 1 | `"guest"` | `"oriveo-images--guest"` |
| 2 | `"abc123"` | `"oriveo-images--abc123"` |

### 1.5 hasPartitionData
| # | Scenario | Expected |
|---|------|------|
| 1 | partition DB does not exist | `false` |
| 2 | partition DB exists but has neither conversations nor providers | `false` |
| 3 | partition has 1 conversation | `true` |
| 4 | partition has 1 provider and no conversation | `true` |
| 5 | partition has both a conversation and a provider | `true` |

### 1.6 metaDBExists / legacyDBExists
| # | Scenario | Expected |
|---|------|------|
| 1 | first launch, no DB at all | both `false` |
| 2 | only the old `"oriveo"` DB exists | `legacyDBExists` = `true`, `metaDBExists` = `false` |
| 3 | after migration | `metaDBExists` = `true` |

---

## 2. idb.ts - partitioned database operations

### 2.1 Partition isolation
| # | Scenario | Expected |
|---|------|------|
| 1 | write a conversation with activeUID = `"guest"`, switch to `"user-A"`, read | the user-A partition does not have that conversation |
| 2 | write a provider as user-A, switch to guest, read | the guest partition does not have that provider |
| 3 | guest and user-A each write one conversation, each reads only its own | data is fully isolated |

### 2.2 resetDBConnection
| # | Scenario | Expected |
|---|------|------|
| 1 | write data, reset, switch activeUID, read again | reads the new partition's data |
| 2 | reset several times in a row | no error |

### 2.3 CRUD in the current partition
| # | Operation | Expected |
|---|------|------|
| 1 | putConversation, then getAllConversations | reads back |
| 2 | putConversation twice with the same ID | the later write replaces the earlier one |
| 3 | deleteConversation | not readable afterwards |
| 4 | putProvider, then getAllProviders | reads back |
| 5 | deleteProvider | not readable afterwards |
| 6 | setSessionValue, then getSessionValue | reads back |
| 7 | getSessionValue for a missing key | returns `undefined` |

---

## 3. image-store.ts - partitioned image storage

### 3.1 Partition isolation
| # | Scenario | Expected |
|---|------|------|
| 1 | saveImage as guest, switch to user-A, loadImageData | returns `null` |
| 2 | saveImage as user-A, switch to guest, imageExists | returns `false` |

### 3.2 resetImageDBConnection
| # | Scenario | Expected |
|---|------|------|
| 1 | write, reset, switch, confirm the old partition is unreadable | isolation holds |

### 3.3 CRUD
| # | Operation | Expected |
|---|------|------|
| 1 | saveImage, then loadImageData | returns the original Blob |
| 2 | saveImage, then loadThumbnailData | returns the thumbnail Blob |
| 3 | saveImage, then imageExists | `true` |
| 4 | deleteImage, then imageExists | `false` |
| 5 | loadImageData for a missing ID | `null` |

---

## 4. migration.ts - migrating older data

### 4.1 Fresh install with no old data
| # | Scenario | Expected |
|---|------|------|
| 1 | no old `"oriveo"` DB | sets activeUID = `"guest"` and marks migration done |
| 2 | called again | skipped straight away, via the localStorage flag |

### 4.2 Old data present
| # | Scenario | Expected |
|---|------|------|
| 1 | the old DB has conversations | migrated into the conversations of `oriveo--guest` |
| 2 | the old DB has providers | migrated into the providers of `oriveo--guest` |
| 3 | the old DB has session data | migrated into the session store of `oriveo--guest` |
| 4 | the old image DB has images | migrated into `oriveo-images--guest` |
| 5 | activeUID after migration = `"guest"` | verified through getActiveUID |
| 6 | localStorage flag after migration = `"true"` | migration marked as done |

### 4.3 Idempotency
| # | Scenario | Expected |
|---|------|------|
| 1 | called again after migration | skipped immediately, nothing written twice |

### 4.4 Fault tolerance
| # | Scenario | Expected |
|---|------|------|
| 1 | the old DB exists but has no conversations store | does not crash, skips that store |
| 2 | the old DB exists but has no providers store | does not crash, skips that store |

---

## 5. auth-service.ts - partition switch on sign-out

### 5.1 signOut
| # | Scenario | Expected |
|---|------|------|
| 1 | activeUID after sign-out | becomes `"guest"` |
| 2 | DB connection after sign-out | resetDBConnection is called |
| 3 | image DB connection after sign-out | resetImageDBConnection is called |
| 4 | the partition switch happens before the Firebase signOut | order is correct: switch the partition first, then sign out of Firebase |

---

## 6. StoreProvider partition switching

### 6.1 Initialization - scenario matrix

| # | Initial activeUID | Firebase user | Expected behaviour |
|---|----------------|--------------|---------|
| 1 | `guest` | `null` (signed out) | hydrate the guest data directly |
| 2 | `user-A` | `user-A` | activeUID === targetUID, hydrate directly |
| 3 | `guest` | `user-A`, guest has no data | switchDB(user-A), then hydrate user-A |
| 4 | `guest` | `user-A`, guest has data, user-A has no history | adopt silently: switchDB(user-A), then persistMemoryToPartition |
| 5 | `guest` | `user-A`, guest has data, user-A has history | set hasPendingDataHandling = true |

### 6.2 Live sign-in events, after hydration

| # | Scenario | Expected |
|---|------|------|
| 1 | skip the first auth callback | no partition switch |
| 2 | sign in as user-A while already on user-A | only the account is updated, no partition switch |
| 3 | sign in as user-A, guest has data, user-A has no history | adopt silently: switchDB, persistMemory, resubscribe |
| 4 | sign in as user-A, guest has data, user-A has history | set pending and hasPendingDataHandling |
| 5 | sign in as user-A, guest has no data | switchDB, clear memory, hydrateStore, resubscribe |

### 6.3 Live sign-out events

| # | Scenario | Expected |
|---|------|------|
| 1 | sign out | clear all in-memory state (account, providers, conversations, pinnedConversationIds and so on) |
| 2 | hasPendingDataHandling after sign-out | reset to `false` |
| 3 | pendingLoginUID after sign-out | reset to `null` |
| 4 | persistence subscription after sign-out | resubscribed (resubscribe is called) |

---

## 7. End-to-end scenarios (integration level)

### 7.1 Guest signs in to a new account (no conflict, silent adoption)
1. As guest, add 1 provider and 1 conversation.
2. Sign in as user-A, who has no prior data.
3. Verify: the user-A partition DB contains the guest provider and conversation.
4. Verify: the in-memory state is unchanged, the provider and conversation are still there.

### 7.2 Guest has data and the account has history (conflict)
1. Write provider-G into the guest partition.
2. Pre-write provider-A into the user-A partition.
3. Hydrate as guest, then sign in as user-A.
4. Verify: store.hasPendingDataHandling = true.
5. Verify: store.pendingLoginUID = "user-A".

### 7.3 User A signs out and user B signs in (data isolation)
1. user-A writes conversation-A.
2. Sign out: activeUID goes to guest and memory is cleared.
3. user-B signs in.
4. Verify: user-B cannot see conversation-A.
5. Verify: the user-A partition DB still has conversation-A.

### 7.4 User A signs out and back in (data recovery)
1. user-A writes a provider and a conversation.
2. Sign out.
3. Sign back in as user-A.
4. Verify: the provider and conversation are fully restored.

### 7.5 Upgrade from an older version (migration)
1. Create an old-format `"oriveo"` DB and write data into it.
2. Call migrateToPartitionedStorage.
3. Verify: `oriveo--guest` holds the complete data.
4. Verify: activeUID = "guest".
5. Verify: calling again does not migrate a second time.

---

## 8. encrypted-keys.ts - partition isolation of encryption keys

### 8.1 Partition isolation
| # | Scenario | Expected |
|---|------|------|
| 1 | store an encrypted key as guest, switch to user-A, read | returns `null`, since partitions do not share a device key |
| 2 | store as user-A, switch back to user-A, read again | decrypts normally |

---

## 9. persistence.ts - hydration and the persistence subscription

### 9.1 hydrateStore
| # | Scenario | Expected |
|---|------|------|
| 1 | IDB has providers and conversations | the store is populated correctly |
| 2 | IDB is empty | the store keeps its defaults |
| 3 | a conversation has a message with state=generating | after hydration the state becomes interrupted |

### 9.2 subscribeToChanges
| # | Scenario | Expected |
|---|------|------|
| 1 | add a provider, IDB has the matching record | persisted successfully |
| 2 | delete a provider, IDB has no matching record | deleted successfully |
| 3 | add a conversation, after the 500ms debounce IDB has the record | persisted successfully |
