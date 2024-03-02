import { EventEmitter } from 'events';
import { Tables } from './db-types';

let emitters: { [profileId: string]: EventEmitter } = {};
export const resetEmitters = () => {
  emitters = {};
};

const getEmitter = (profileId: string) => {
  if (!emitters[profileId]) {
    emitters[profileId] = new EventEmitter();
  }

  return emitters[profileId];
};

type FormatInsertedEvent<S extends string> = `inserted:${S}`;

type AllInsertEvents = {
  [Table in keyof Tables as FormatInsertedEvent<Table>]: Tables[Table];
};

interface OtherEvents {
  ['fulfilled:phone_number_request']: Tables['phone_number_requests'];
  ['modified:sending_locations']: Tables['sending_locations'];
}

type SwitchboardEvents = AllInsertEvents & OtherEvents;

/* tslint:disable */
// tslint is telling me that Key is shadowed below, but it's not
// I don't think it's been maintained for later Typescript versions
export const SwitchboardEmitter = {
  on: <Key extends keyof SwitchboardEvents>(
    profileId: string,
    event: Key,
    handler: (payload: SwitchboardEvents[Key]) => unknown
  ) => {
    getEmitter(profileId).on(event, handler);
  },
  emit: <Key extends keyof SwitchboardEvents>(
    profileId: string,
    event: Key,
    payload: SwitchboardEvents[Key]
  ) => {
    getEmitter(profileId).emit(event, payload);
  },
  offAll: <Key extends keyof SwitchboardEvents>(
    profileId: string,
    event: Key
  ) => {
    getEmitter(profileId).removeAllListeners(event);
  },
};
