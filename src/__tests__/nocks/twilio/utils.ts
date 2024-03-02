import faker from 'faker';

export const fakeSid = () => `PN${faker.random.alphaNumeric(32)}`;
