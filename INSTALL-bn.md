# RANIBO ইনস্টল ও চালানোর গাইড (শুরু থেকে)

এই গাইড ধরে নেয় আপনার GitHub Codespace-এ `ranibo-app` ফোল্ডার আছে, যেখানে Phase 1 ও Phase 2 আছে।
এখনো কিছু চালিয়ে পরীক্ষা করা হয়নি। প্রতিটি ধাপের শেষে "কী দেখা উচিত" লেখা আছে। না মিললে error হুবহু আমাকে পাঠান।

## ধাপ ১: কোডের জায়গা খোলা

1. ব্রাউজারে github.com খুলে লগইন করুন।
2. **Your repositories** থেকে `ranibo-app` খুলুন।
3. সবুজ **Code** বাটন চাপুন, **Codespaces** ট্যাব থেকে আগের Codespace খুলুন (না থাকলে **Create codespace**)।
4. ব্রাউজারে VS Code খুলবে।

## ধাপ ২: টার্মিনাল খোলা

VS Code-এর উপরের মেনু: **Terminal → New Terminal**। নিচে একটা প্যানেল খুলবে। নিচের সব কমান্ড ওখানে paste করে **Enter** চাপবেন।

## ধাপ ৩: ঠিক জায়গায় আছেন কি না দেখা

```bash
ls
```

**দেখা উচিত:** `package.json`, `src`, `supabase` এই নামগুলো। না দেখলে `cd ranibo-app` লিখে আবার `ls` চালান।

## ধাপ ৪: প্যাকেজ ইনস্টল

```bash
node -v
npm -v
npm install
```

**দেখা উচিত:** `node -v` একটা সংখ্যা দেখাবে (যেমন v20 বা v22)। `npm install` কয়েক মিনিট নিতে পারে, শেষে `added ... packages` লেখা আসবে। লাল `npm ERR!` এলে পুরোটা পাঠান।

## ধাপ ৫: Supabase-এর চাবি (.env.local)

1. supabase.com-এ আপনার প্রজেক্ট খুলুন: **Project Settings → API**।
2. `ranibo-app` ফোল্ডারের `.env.local` ফাইলটা খুলুন (আগে থেকে থাকলে বদলাবেন না)।
3. ফাইলে যে নামগুলো আছে তার পাশে Supabase-এর URL ও public (anon) key বসান।

নিয়ম: **service_role key কখনো এই ফাইলে বা কোডে বসাবেন না, আর কাউকে (আমাকেও) পাঠাবেন না।** `.env.local` ফাইলও আমাকে পাঠাবেন না।

## ধাপ ৬: ডাটাবেস সেটআপ (Supabase SQL Editor)

Supabase → **SQL Editor → New query**। প্রতিটি ফাইল পুরো paste করে **Run**, **একবারই**, এই ক্রমে:

1. Phase 1-এর SQL (আগে চালিয়ে থাকলে আবার নয়)।
2. `supabase/migrations/20261011000002_phase2_products_orders.sql`
3. **Phase 3 SQL এখনই চালাবেন না।** আগে `README-phase3.md`-র নিয়মে scratch ডাটাবেসে টেস্ট চালাতে হবে।

কোনো ফাংশন "not found" বললে চালান: `notify pgrst, 'reload schema';`

## ধাপ ৭: Phase 2 ফাইল বসানো (আগে না বসালে)

`ranibo-phase2.zip` ফাইলটা Codespace-এর ফাইল তালিকায় টেনে ফেলুন, তারপর:

```bash
unzip -o ranibo-phase2.zip -d phase2-files
cp -r phase2-files/ranibo/src/. src/
cp -r phase2-files/ranibo/supabase/. supabase/
```

## ধাপ ৮: যাচাই (চালানোর আগে)

```bash
npx tsc --noEmit
npm run lint
npm run build
```

**দেখা উচিত:** কোনো লাল error ছাড়া শেষ হওয়া। error এলে পুরো লেখা কপি করে আমাকে পাঠান, আমি এক এক করে ঠিক করব।

## ধাপ ৯: অ্যাপ চালানো

```bash
npm run dev
```

1. VS Code-এর নিচে **Ports** ট্যাব খুলুন।
2. 3000 পোর্টের পাশের ঠিকানা (URL) কপি করুন।
3. নতুন ব্রাউজার ট্যাবে বা Android Chrome-এ খুলুন।

**দেখা উচিত:** RANIBO-র লগইন পেজ। সাইনআপ করে ব্যবসা বানান, তারপর Products ও Orders মেনু দেখুন।

## ধাপ ১০: কাজ শেষে

- টার্মিনালে `Ctrl + C` চেপে অ্যাপ থামান।
- Codespace বন্ধ করুন (বাঁদিকের নিচে Codespaces লেখায় ক্লিক → **Stop Current Codespace**)। না করলে ফ্রি ঘণ্টা খরচ হতে থাকবে।
- কাজ GitHub-এ সেভ: `git add .` তারপর `git commit -m "my update"` তারপর `git push`। `.env.local` কখনো GitHub-এ যাবে না, এটা `.gitignore`-এ আছে কি না আমাকে `cat .gitignore` চালিয়ে দেখান।
