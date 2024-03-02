/* tslint:disable */
import twilio from 'twilio';

const SID = process.env.TWILIO_ACCOUNT_SID;
const TOKEN = process.env.TWILIO_AUTH_TOKEN;

console.log({ SID, TOKEN });

const instance = twilio(SID, TOKEN);

const voiceUrl = process.env.VOICE_URL;

const main = async () => {
  const count = await instance.incomingPhoneNumbers.list({});
  console.log(count);

  await instance.incomingPhoneNumbers.each({}, async phone => {
    console.log(phone.voiceUrl);
    console.log(phone.phoneNumber);
    await phone.update({ voiceUrl });
    console.log('updated');
  });
};

main()
  .then(console.log)
  .catch(console.error);
