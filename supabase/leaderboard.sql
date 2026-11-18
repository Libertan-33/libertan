-- レンタルりばたん: 世界ランキング用(Supabase の SQL Editor に丸ごと貼って Run)
-- 何度実行しても壊れません。

create table if not exists public.lb_players (
  no            bigint generated always as identity primary key,
  secret        uuid not null default gen_random_uuid(),
  cc            text check (cc is null or cc ~ '^[A-Z]{2}$'),
  total         numeric not null default 0 check (total >= 0 and total < 1e40),
  d_key text, d_base numeric not null default 0,
  w_key text, w_base numeric not null default 0,
  m_key text, m_base numeric not null default 0,
  submitted_at  timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

-- 表には直接さわれないようにする(関数経由だけ)
alter table public.lb_players enable row level security;
revoke all on public.lb_players from anon, authenticated;

create index if not exists lb_players_total_idx on public.lb_players (total desc);

-- 日本時間での「今日 / 今週(月曜はじまり) / 今月」のキー
create or replace function public.lb_keys(out dk text, out wk text, out mk text)
language sql stable set search_path = public as $$
  select to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD'),
         to_char(date_trunc('week', now() at time zone 'Asia/Tokyo'), 'YYYY-MM-DD'),
         to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM');
$$;

-- 端末の登録: 番号(変態No.)と合言葉を発行
create or replace function public.lb_register(p_cc text default null)
returns json language plpgsql security definer set search_path = public as $$
declare r public.lb_players;
begin
  insert into public.lb_players (cc)
  values (case when p_cc ~ '^[A-Z]{2}$' then p_cc else null end)
  returning * into r;
  return json_build_object('no', r.no, 'secret', r.secret);
end $$;

-- 得点の送信(合計だけ送る。日・週・月は、こちらで基準点から計算)
create or replace function public.lb_submit(p_no bigint, p_secret uuid, p_total text, p_cc text default null)
returns json language plpgsql security definer set search_path = public as $$
declare r public.lb_players; k record; t numeric;
begin
  if p_total is null or p_total !~ '^[0-9]{1,38}$' then return json_build_object('ok', false, 'why', 'bad_total'); end if;
  t := p_total::numeric;
  select * into r from public.lb_players where no = p_no and secret = p_secret for update;
  if not found then return json_build_object('ok', false, 'why', 'unknown'); end if;
  if now() - r.submitted_at < interval '2 seconds' then return json_build_object('ok', true, 'skipped', true); end if;
  if t < r.total then return json_build_object('ok', false, 'why', 'decrease'); end if;
  if t - r.total > 1e21 then return json_build_object('ok', false, 'why', 'too_big'); end if;
  select * into k from public.lb_keys();
  update public.lb_players set
    total = t,
    cc = case when p_cc ~ '^[A-Z]{2}$' then p_cc else cc end,
    d_base = case when d_key is null then t when d_key is distinct from k.dk then r.total else d_base end, d_key = k.dk,
    w_base = case when w_key is null then t when w_key is distinct from k.wk then r.total else w_base end, w_key = k.wk,
    m_base = case when m_key is null then t when m_key is distinct from k.mk then r.total else m_base end, m_key = k.mk,
    submitted_at = now()
  where no = p_no;
  return json_build_object('ok', true);
end $$;

-- 期間ごとの得点一覧(内部用)
create or replace function public.lb_scores(p_period text)
returns table (no bigint, cc text, s numeric)
language sql stable security definer set search_path = public as $$
  select p.no, p.cc,
    case p_period
      when 'd' then case when p.d_key = k.dk then p.total - p.d_base else 0 end
      when 'w' then case when p.w_key = k.wk then p.total - p.w_base else 0 end
      when 'm' then case when p.m_key = k.mk then p.total - p.m_base else 0 end
      else p.total end
  from public.lb_players p, public.lb_keys() k;
$$;

-- ランキング取得: 上位30人 + 自分の順位。p_period は d / w / m / t
create or replace function public.lb_board(p_period text, p_no bigint default null)
returns json language plpgsql security definer set search_path = public as $$
declare top json; cnt bigint; mine numeric; ahead bigint;
begin
  if p_period is null or p_period not in ('d','w','m','t') then p_period := 't'; end if;
  select coalesce(json_agg(json_build_object('no', x.no, 'cc', x.cc, 's', x.s::text) order by x.s desc, x.no), '[]'::json)
    into top from (select * from public.lb_scores(p_period) where s > 0 order by s desc, no limit 30) x;
  select count(*) into cnt from public.lb_scores(p_period) where s > 0;
  if p_no is not null then
    select s into mine from public.lb_scores(p_period) where no = p_no and s > 0;
    if mine is not null then select count(*) into ahead from public.lb_scores(p_period) where s > mine; end if;
  end if;
  return json_build_object('top', top, 'count', cnt, 'ahead', ahead, 'mine', mine::text);
end $$;

revoke all on function public.lb_register(text), public.lb_submit(bigint, uuid, text, text), public.lb_board(text, bigint), public.lb_keys(), public.lb_scores(text) from public, anon, authenticated;
grant execute on function public.lb_register(text), public.lb_submit(bigint, uuid, text, text), public.lb_board(text, bigint) to anon, authenticated;
