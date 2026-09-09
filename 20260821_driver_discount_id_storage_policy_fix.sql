-- Allows eligible drivers to view companion discount ID images while a booking
-- is still pending/unassigned, so they can inspect the ID before accepting.

drop policy if exists discount_ids_assigned_driver_read on storage.objects;

create policy discount_ids_assigned_driver_read
on storage.objects for select using (
  bucket_id = 'discount-ids'
  and exists (
    select 1
    from public.booking_discount_requests bdr
    join public.bookings b on b.id = bdr.booking_id
    where bdr.id_image_path = storage.objects.name
      and (
        b.driver_id = public.current_driver_id()
        or (
          b.status in ('pending', 'searching')
          and b.driver_id is null
          and public.current_driver_can_view_bookings()
        )
      )
  )
);
