drop index sms.unqiue_number_for_unfulfilled_service_order_id;
drop index sms.unqiue_number_for_unfulfilled_fulfilled_at;

update sms.phone_number_requests pnr
set service_order_id = null
where service_order_id = 'legacy';
