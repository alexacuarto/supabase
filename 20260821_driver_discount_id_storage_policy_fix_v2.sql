-- Broader driver read policy for discount ID previews.
-- Use this if drivers can see a pending ride but createSignedUrl still fails.

drop policy if exists discount_ids_assigned_driver_read on storage.objects;

create policy discount_ids_assigned_driver_read
on storage.objects for select using (
  bucket_id = 'discount-ids'
  and public.current_driver_id() is not null
  and exists (
    select 1
    from public.bookings b
    left join public.booking_discount_requests bdr on bdr.booking_id = b.id
    where (
        bdr.id_image_path = storage.objects.name
        or b.discount_id_image = storage.objects.name
      )
      and (
        b.driver_id = public.current_driver_id()
        or (
          b.status in ('pending', 'searching')
          and b.driver_id is null
        )
      )
  )
);
