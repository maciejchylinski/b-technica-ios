# Local Supabase configuration

1. Copy `Secrets.xcconfig.example` to `Secrets.xcconfig`.
2. Fill `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the Supabase Dashboard → **Settings → API**.
3. Use the **anon / publishable** key only. Never put the `service_role` key in the iOS app or in Git.

`Secrets.xcconfig` is gitignored. `Base.xcconfig` includes it optionally so clones without secrets still open in Xcode.

Initial account credentials for local development (if created by the setup agent) live only under the gitignored `.secrets/` folder on the machine that ran setup.
