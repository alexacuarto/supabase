-- Fix duplicate booking_number errors during quick retries/concurrent booking inserts.
-- Run this once in Supabase SQL Editor on an existing TodaGo database.

create sequence if not exists public.booking_number_seq;

select setval(
  'public.booking_number_seq',
  greatest(
    coalesce(
      (
        select max((substring(booking_number from '([0-9]+)$'))::bigint)
        from public.bookings
        where booking_number ~ '^TG-[0-9]{8}-[0-9]+$'
      ),
      0
    ),
    1
  ),
  true
);

create or replace function public.generate_booking_number()
returns trigger
language plpgsql
as $$
declare
  sequence_value bigint;
begin
  if new.booking_number is not null then
    return new;
  end if;

  sequence_value := nextval('public.booking_number_seq');

  new.booking_number :=
    'TG-' ||
    to_char(coalesce(new.created_at, now()) at time zone 'Asia/Manila', 'YYYYMMDD') ||
    '-' ||
    lpad(sequence_value::text, 6, '0');

  return new;
end;
$$;

drop trigger if exists before_booking_insert on public.bookings;
create trigger before_booking_insert
  before insert on public.bookings
  for each row execute function public.generate_booking_number();
