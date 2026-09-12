-- Migration: Support Passenger Feedback from Drivers and Ensure RLS Compatibility
alter table public.reports
  add column if not exists passenger_id uuid references public.passengers(id) on delete set null;

create index if not exists idx_reports_passenger on public.reports(passenger_id, created_at desc);

-- Ensure RLS allows both passengers and drivers to submit feedback
drop policy if exists reports_insert_passenger on public.reports;
drop policy if exists reports_insert_authenticated on public.reports;

create policy reports_insert_authenticated on public.reports for insert with check (
  reporter_profile_id = auth.uid()
);
