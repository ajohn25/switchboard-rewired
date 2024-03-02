/* tslint:disable */
import twilio from 'twilio';

const instance = twilio(
  process.env.TWILIO_ACCOUNT_SID,
  process.env.TWILIO_AUTH_TOKEN
);

const main = async () => {
  const page = await instance.incomingPhoneNumbers.each(
    {},
    async (phone, done) => {
      await phone.remove();
      console.log('Removed ', phone.phoneNumber);
      // process.exit();
    }
  );
};

main()
  .then(console.log)
  .catch(console.error);
