# EMG Staffing Assignments

Staffing & profitability planner. Single-file app hosted on GitHub Pages, data in Supabase.

## Automatic QuickBooks Time sync

A GitHub Action (`.github/workflows/sync-qbtime.yml`) pulls hours from QuickBooks Time every day at 07:00 UTC and writes them into the ledger as **actuals** for the current month plus the two previous months. Those months are treated as fully owned by QuickBooks Time — each sync replaces them, so corrections and deletions in QB Time flow through.

### One-time setup
1. **Get a QuickBooks Time API token**: in QuickBooks Time, go to **Feature Add-ons → Manage Add-ons → API** and install it, then open the API add-on and choose **Add Token**. Copy the access token. (If your account was migrated to Intuit sign-in and this screen looks different, an admin may need to create the token via the Intuit developer portal instead.)
2. **Get your Supabase service-role key**: Supabase dashboard → Project Settings → API → `service_role` key. This key bypasses row security — it must only ever live in GitHub secrets, never in the app code.
3. **Add both as repository secrets**: GitHub repo → Settings → Secrets and variables → Actions → New repository secret:
   - `QBTIME_TOKEN`
   - `SUPABASE_SERVICE_ROLE_KEY`
4. **Test it**: repo → Actions → "Sync QuickBooks Time actuals" → Run workflow. The log shows how many entries were pulled and which months were written.

### How mapping works
- The **person** is the QB Time user's first + last name, matched case-insensitively to the Team list; unknown people are created (with $0 cost — set it in the Team tab).
- The **project** is the top-level parent jobcode (the customer), so hours logged against sub-jobs roll up to the customer. Jobcodes named Internal / Non-billable / Admin / Overhead go to internal hours.
- Unknown customers become new projects with $0 revenue — set revenue in the Projects tab.
