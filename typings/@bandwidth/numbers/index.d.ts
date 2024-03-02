// Ref: https://github.com/Bandwidth/node-numbers/issues/14

declare module '@bandwidth/numbers' {
  type RequireOnlyOne<T, Keys extends keyof T = keyof T> = Pick<
    T,
    Exclude<keyof T, Keys>
  > &
    {
      [K in Keys]-?: Required<Pick<T, K>> &
        Partial<Record<Exclude<Keys, K>, unknown>>;
    }[Keys];

  type Callback<T> = (error: Error | null, data: T) => void;

  type DateStr = string;

  type State = 'MA' | string;
  type Country = 'United States' | string;
  type VendorId = 49 | number;
  type VendorName = 'Bandwidth CLEC' | string;
  type Tier = 1 | 2 | 3 | 4 | 5;

  type Links = {
    first: string;
    last?: string;
  };

  type TelephoneNumberType = {
    city: string;
    lata: number;
    state: State;
    fullNumber: string;
    tier: Tier;
    vendorId: VendorId;
    vendorName: VendorName;
    onNetVendor: boolean;
    rateCenter: string;
    status: 'Inservice';
    accountId: number;
    lastModified: DateStr;
    client: Client.Client;
  };

  type Query = {
    page: string | number;
    size: number;
  };

  // Client

  export class Client {
    constructor(
      accountId: string,
      userName: string,
      password: string
    );

    static getIdFromHeader(): void;

    static getIdFromLocationHeader(): void;

    static getIdFromHeaderAsync(): void;

    static getIdFromLocationHeaderAsync(): void;

    static globalOptions: {
      apiEndPoint: string;
      userName: string;
      password: string;
      accountId: string;
    };

    public prepareRequest: () => void;
    public concatAccountPath: () => void;
    public prepareUrl: () => void;
    public xml2jsParserOptions: {
      explicitArray: boolean;
      tagNameProcessors: Array<null>;
      async: boolean;
    };
  }

  type List<T extends object, Q extends object> = {
    list: (query: Q, callback: Callback<T>) => void;
    listAsync: (query: Q) => Promise<T>;
  };

  // Account

  type AccountGetResult = {
    accountId: number;
    globalAccountNumber: string;
    associatedCatapultAccount: number;
    companyName: string;
    accountType: 'Business' | string;
    tiers: { tier: Array<Tier> };
    address: {
      houseNumber: number;
      streetName: string;
      city: string;
      stateCode: State;
      zip: number;
      country: Country;
      addressType: 'Service' | string;
    };
    contact: {
      firstName: string;
      lastName: string;
      phone: string;
      email: string;
    };
    sPID: 'mult' | string;
    portCarrierType: 'WIRELINE' | string;
    default911Provider: 'EVS' | string;
    customerSegment: 'Wholesale' | string;
  };

  namespace Account {
    function get(callback: Callback<AccountGetResult>): void;
    function get(
      client: Client,
      callback: Callback<AccountGetResult>
    ): void;

    function getAsync(): Promise<AccountGetResult>;
    function getAsync(client: Client.Client): Promise<AccountGetResult>;
  }

  // AvailableNpaNxx

  type AvailableNpaNxxListQuery = RequireOnlyOne<
    {
      areaCode?: number;
      quantity?: number;
      state?: State;
    },
    'areaCode' | 'quantity' | 'state'
  >;

  type AvailableNpaNxxListResult = Array<{
    city: string;
    npa: number;
    nxx: number;
    quantity: number;
    state: State;
  }>;

  namespace AvailableNpaNxx {
    function list(
      query: AvailableNpaNxxListQuery,
      callback: Callback<AvailableNpaNxxListResult>
    ): void;
    function list(
      client: Client,
      query: AvailableNpaNxxListQuery,
      callback: Callback<AvailableNpaNxxListResult>
    ): void;

    function listAsync(
      query: AvailableNpaNxxListQuery
    ): Promise<AvailableNpaNxxListResult>;
    function listAsync(
      client: Client,
      query: AvailableNpaNxxListQuery
    ): Promise<AvailableNpaNxxListResult>;
  }

  // AvailableNumbers

  type AvailableNumbersListQuery = RequireOnlyOne<
    {
      LCA?: boolean;
      areaCode?: number | string;
      city?: string;
      enableTNDetail?: boolean;
      endsIn?: boolean;
      lata?: number;
      localVanity?: string;
      npaNxx?: number | string;
      npaNxxx?: number | string;
      orderBy?: 'fullNumber' | 'npaNxxx' | 'npaNxx' | 'areaCode';
      rateCenter?: string;
      state?: State;
      tollFreeVanity?: string;
      tollFreeWildCardPattern?: string;
      zip?: number;
      quantity?: number;
    },
    | 'LCA'
    | 'areaCode'
    | 'city'
    | 'enableTNDetail'
    | 'endsIn'
    | 'lata'
    | 'localVanity'
    | 'npaNxx'
    | 'npaNxxx'
    | 'orderBy'
    | 'rateCenter'
    | 'state'
    | 'tollFreeVanity'
    | 'tollFreeWildCardPattern'
    | 'zip'
  >;

  type AvailableNumbersListResult = {
    resultCount: number;
    telephoneNumberList: {
      telephoneNumber: Array<string>;
    };
  };

  namespace AvailableNumbers {
    function list(
      query: AvailableNumbersListQuery,
      callback: Callback<AvailableNumbersListResult>
    ): void;
    function list(
      client: Client,
      query: AvailableNumbersListQuery,
      callback: Callback<AvailableNumbersListResult>
    ): void;

    function listAsync(
      query: AvailableNumbersListQuery
    ): Promise<AvailableNumbersListResult>;
    function listAsync(
      client: Client,
      query: AvailableNumbersListQuery
    ): Promise<AvailableNumbersListResult>;
  }

  // City

  type CityListQuery = {
    available?: boolean;
    state: State;
    supported?: boolean;
  };

  type CityListResult = Array<{
    rcAbbreviation: string;
    name: string;
  }>;

  namespace City {
    function list(
      query: CityListQuery,
      callback: Callback<CityListResult>
    ): void;
    function list(
      client: Client,
      query: CityListQuery,
      callback: Callback<CityListResult>
    ): void;

    function listAsync(query: CityListQuery): Promise<CityListResult>;
    function listAsync(
      client: Client,
      query: CityListQuery
    ): Promise<CityListResult>;
  }

  // CoveredRateCenter

  type CoveredRateCenterQuery = Query & {
    abbreviation?: string;
    city?: string;
    embed?:
      | 'ZipCodes'
      | 'Cities'
      | 'Vendors'
      | 'Npa'
      | 'NpaNxxX'
      | 'AvailableNumberCount'
      | 'LimitedAvailableNumberCount'
      | 'LocalRateCenters';
    lata?: string;
    name?: string;
    npa?: number;
    npaNxx?: number;
    npaNxxX?: number;
    state?: State;
    tier?: Tier;
    zip?: number;
  };

  type CoveredRateCenterResult = Array<{
    id: number;
    name: string;
    abbreviation: string;
    state: State;
    lata: number;
    tiers: {
      tier: Tier;
    };
  }>;

  namespace CoveredRateCenter {
    function list(
      query: CoveredRateCenterQuery,
      callback: Callback<CoveredRateCenterResult>
    ): void;
    function list(
      client: Client,
      query: CoveredRateCenterQuery,
      callback: Callback<CoveredRateCenterResult>
    ): void;

    function listAsync(
      query: CoveredRateCenterQuery
    ): Promise<CoveredRateCenterResult>;
    function listAsync(
      client: Client,
      query: CoveredRateCenterQuery
    ): Promise<CoveredRateCenterResult>;
  }

  // CsrOrder

  // Wasn't able to test any of the CsrOrder endpoints so these are my best guess based on the api reference.
  type CsrOrderGetResult = {
    customerOrderId: string;
    lastModifiedBy: string;
    orderCreateDate: DateStr;
    accountId: number;
    orderId: string;
    lastModifiedDate: DateStr;
    status: OrderStatus;
    accountNumber: number;
    accountTelephoneNumber: number;
    endUserName: string;
    authorizingUserName: string;
    customerCode: number;
    endUserPIN: number;
    addressLine1: string;
    city: string;
    state: State;
    zipCode: number;
    typeOfService: 'residential' | string;
    csrData: {
      accountNumber: number;
      customerName: string;
      serviceAddress: {
        unparsedAddress: string;
        city: string;
        state: State;
        zip: number;
      };
      workingTelephoneNumber: number;
      workingTelephoneNumbersOnAccount: {
        telephoneNumber: number;
      };
    };
  };

  namespace CsrOrder {
    function get(id: string, callback: Callback<CsrOrderGetResult>): void;
    function get(
      client: Client,
      id: string,
      callback: Callback<CsrOrderGetResult>
    ): void;

    function getAsync(id: string): Promise<CsrOrderGetResult>;
    function getAsync(
      client: Client,
      id: string
    ): Promise<CsrOrderGetResult>;

    // Can't find create in the api reference so unsure what the types are.
    function create(date: unknown, callback: Callback<unknown>): void;
    function create(
      client: Client,
      date: unknown,
      callback: Callback<unknown>
    ): void;

    function createAsync(date: unknown): Promise<unknown>;
    function createAsync(
      client: Client,
      date: unknown
    ): Promise<unknown>;
  }

  export function CsrOrder(): void;

  // DiscNumber

  // Wasn't able to test this fully since I had no disconnected numbers.

  namespace DiscNumber {
    type DiscNumberListQuery = Query & { enddate?: string; startdate?: string };

    type DiscNumberListResult = {
      count: number;
      telephoneNumber?: Array<string>;
    };

    type DiscNumberTotalResult = {
      count: number;
    };

    function list(
      query: DiscNumberListQuery,
      callback: Callback<DiscNumberListResult>
    ): void;
    function list(
      client: Client,
      query: DiscNumberListQuery,
      callback: Callback<DiscNumberListResult>
    ): void;

    function listAsync(
      query: DiscNumberListQuery
    ): Promise<DiscNumberListResult>;
    function listAsync(
      client: Client,
      query: DiscNumberListQuery
    ): Promise<DiscNumberListResult>;

    function totals(callback: Callback<DiscNumberTotalResult>): void;
    function totals(
      client: Client,
      callback: Callback<DiscNumberTotalResult>
    ): void;

    function totalsAsync(
      client?: Client.Client
    ): Promise<DiscNumberTotalResult>;
  }

  // Disconnect

  namespace Disconnect {
    type DisconnectListQuery = Query & {
      enddate?: string;
      startdate?: string;
      status?: 'complete' | string;
      userid?: string;
    };

    type DisconnectListResult = {
      ListOrderIdUserIdDate: {
        TotalCount: number;
        Links: Links;
        OrderIdUserIdDate: Array<{
          CountOfTNs: number;
          userId: string;
          lastModifiedDate: DateStr;
          OrderId: string;
          OrderType: 'disconnect' | string;
          OrderDate: DateStr;
          OrderStatus: OrderStatus;
          TelephoneNumberDetails: {};
        }>;
      };
    };

    type DisconnectGetQuery = {
      tndetail?: boolean;
    };

    function create(
      orderName: string,
      numbers: Array<string>,
      callback: Callback<unknown>
    ): void;
    function create(
      client: Client,
      orderName: string,
      numbers: Array<string>,
      callback: Callback<unknown>
    ): void;

    function createAsync(
      orderName: string,
      numbers: Array<string>
    ): Promise<unknown>;
    function createAsync(
      client: Client,
      orderName: string,
      numbers: Array<string>
    ): Promise<unknown>;

    function list(
      query: DisconnectListQuery,
      callback: Callback<DisconnectListResult>
    ): void;
    function list(
      client: Client,
      query: DisconnectListQuery,
      callback: Callback<DisconnectListResult>
    ): void;

    function listAsync(
      query: DisconnectListQuery
    ): Promise<DisconnectListResult>;
    function listAsync(
      client: Client,
      query: DisconnectListQuery
    ): Promise<DisconnectListResult>;

    function get(
      id: string,
      query: DisconnectGetQuery,
      callback: Callback<unknown>
    ): void;
    function get(
      client: Client,
      id: string,
      query: DisconnectGetQuery,
      callback: Callback<unknown>
    ): void;

    function getAsync(id: string, query: DisconnectGetQuery): Promise<unknown>;
    function getAsync(
      client: Client,
      id: string,
      query: DisconnectGetQuery
    ): Promise<unknown>;
  }

  export function Disconnect(): void;

  // Dlda

  namespace Dlda {
    type DldaCreateItem = {
      customerOrderId: string;
      dldaTnGroups: {
        dldaTnGroup: {
          telephoneNumbers: { telephoneNumber: string };
          subscriberType: 'RESIDENTIAL' | string;
          listingType: 'LISTED' | string;
          listingName: {
            firstName: string;
            lastName: string;
          };
          listAddress: boolean;
          address: {
            houseNumber: number;
            streetName: string;
            streetSuffix: string;
            city: string;
            stateCode: State;
            zip: number;
            addressType: 'DLDA' | string;
          };
        };
      };
    };

    type DldaListQuery = {
      lastModifiedAfter?: string;
      modifiedDateFrom?: string;
      modifiedDateTo?: string;
      tn?: string;
    };

    type DldaListResult = {
      listOrderIdUserIdDate: { totalCount: number };
    };

    function create(item: DldaCreateItem, callback: Callback<unknown>): void;
    function create(
      client: Client,
      item: DldaCreateItem,
      callback: Callback<unknown>
    ): void;

    function createAsync(item: DldaCreateItem): Promise<unknown>;
    function createAsync(
      client: Client,
      item: DldaCreateItem
    ): Promise<unknown>;

    function list(
      query: DldaListQuery,
      callback: Callback<DldaListResult>
    ): void;
    function list(
      client: Client,
      query: DldaListQuery,
      callback: Callback<DldaListResult>
    ): void;

    function listAsync(query: DldaListQuery): Promise<DldaListResult>;
    function listAsync(
      client: Client,
      query: DldaListQuery
    ): Promise<DldaListResult>;

    function get(id: string, callback: Callback<unknown>): void;
    function get(
      client: Client,
      id: string,
      callback: Callback<unknown>
    ): void;

    function getAsync(id: string): Promise<unknown>;
    function getAsync(client: Client, id: string): Promise<unknown>;
  }

  export function Dlda(): void;

  // ImportTnChecker

  namespace ImportTnChecker {
    type ImportTnCheckerResult = {
      importTnCheckerPayload: {
        telephoneNumbers: number;
        importTnErrors?: {
          importTnError: {
            code: 19005 | number;
            description:
              | 'Messaging route of External Third Party TNs is not configured.'
              | string;
            telephoneNumbers: { telephoneNumber: string };
          };
        };
      };
    };

    function check(
      numbers: Array<string>,
      callback: Callback<ImportTnCheckerResult>
    ): void;
    function check(
      client: Client,
      numbers: Array<string>,
      callback: Callback<ImportTnCheckerResult>
    ): void;

    function checkAsync(numbers: Array<string>): Promise<ImportTnCheckerResult>;
    function checkAsync(
      client: Client,
      numbers: Array<string>
    ): Promise<ImportTnCheckerResult>;
  }

  // ImportTnOrder

  namespace ImportTnOrder {
    type ImportTnOrderData = {
      customerOrderID: string;
      siteId: number;
      sipPeerId: number;
      subscriber: {
        mame: string;
        serviceAddress: {
          houseNumber: number;
          streetName: string;
          city: string;
          stateCode: State;
          zip: number;
          county: string;
        };
      };
      loaAuthorizingPerson: string;
      loaType: 'CARRIER' | string;
      telephoneNumbers: {
        telephoneNumber: Array<string>;
      };
    };

    type ImportTnOrderListQuery = {
      createdDateFrom?: string;
      createdDateTo?: string;
      customerOrderId?: string;
      loaType?: 'CARRIER' | 'SUBSCRIBER';
      modifiedDateFrom?: string;
      status?: 'RECEIVED' | 'PROCESSING' | 'COMPLETE' | 'PARTIAL' | 'FAILED';
      tn?: string;
    };

    type ImportTnOrderListResult = {
      totalCount: number;
    };

    function create(
      data: ImportTnOrderData,
      numbers: Array<string>,
      callback: Callback<unknown>
    ): void;
    function create(
      client: Client,
      data: ImportTnOrderData,
      numbers: Array<string>,
      callback: Callback<unknown>
    ): void;

    function createAsync(
      data: ImportTnOrderData,
      numbers: Array<string>
    ): Promise<unknown>;
    function createAsync(
      client: Client,
      data: ImportTnOrderData,
      numbers: Array<string>
    ): Promise<unknown>;

    function get(id: string, callback: Callback<unknown>): void;
    function get(
      client: Client,
      id: string,
      callback: Callback<unknown>
    ): void;

    function getAsync(id: string): Promise<unknown>;
    function getAsync(client: Client, id: string): Promise<unknown>;

    function list(
      query: ImportTnOrderListQuery,
      callback: Callback<ImportTnOrderListResult>
    ): void;
    function list(
      client: Client,
      query: ImportTnOrderListQuery,
      callback: Callback<ImportTnOrderListResult>
    ): void;

    function listAsync(
      query: ImportTnOrderListQuery
    ): Promise<ImportTnOrderListResult>;
    function listAsync(
      client: Client,
      query: ImportTnOrderListQuery
    ): Promise<ImportTnOrderListResult>;
  }

  export function ImportTnOrder(): void;

  // ImportToAccount

  namespace ImportToAccount {
    function create(item: unknown, callback: Callback<unknown>): void;
    function create(
      client: Client,
      item: unknown,
      callback: Callback<unknown>
    ): void;

    function createAsync(item: unknown): Promise<unknown>;
    function createAsync(
      client: Client,
      item: unknown
    ): Promise<unknown>;

    function list(query: unknown, callback: Callback<unknown>): void;
    function list(
      client: Client,
      query: unknown,
      callback: Callback<unknown>
    ): void;

    function listAsync(query: unknown): Promise<unknown>;
    function listAsync(client: Client, query: unknown): Promise<unknown>;
  }

  export function ImportToAccount(): void;

  // InServiceNumber

  namespace InServiceNumber {
    type InServiceNumberListQuery = Query & {
      areacode?: string;
      enddate?: string;
      lata?: number;
      npanxx?: number;
      ratecenter?: string;
      startdate?: string;
      state?: State;
    };

    type InServiceNumberListResult = {
      totalCount: number;
      links: Links;
      telephoneNumbers: {
        count: number;
        telephoneNumber: string | Array<string>;
      };
    };

    type InServiceNumberTotalsResult = {
      count: number;
    };

    type InServiceNumberGetResult = {};

    function list(
      query: InServiceNumberListQuery,
      callback: Callback<InServiceNumberListResult>
    ): void;
    function list(
      client: Client,
      query: InServiceNumberListQuery,
      callback: Callback<InServiceNumberListResult>
    ): void;

    function listAsync(
      query: InServiceNumberListQuery
    ): Promise<InServiceNumberListResult>;
    function listAsync(
      client: Client,
      query: InServiceNumberListQuery
    ): Promise<InServiceNumberListResult>;

    function totals(callback: Callback<InServiceNumberTotalsResult>): void;
    function totals(
      client: Client,
      callback: Callback<InServiceNumberTotalsResult>
    ): void;

    function totalsAsync(
      client?: Client.Client
    ): Promise<InServiceNumberTotalsResult>;

    function get(
      number: string,
      callback: Callback<InServiceNumberGetResult>
    ): void;
    function get(
      client: Client,
      number: string,
      callback: Callback<InServiceNumberGetResult>
    ): void;

    function getAsync(number: string): Promise<InServiceNumberGetResult>;
    function getAsync(
      client: Client,
      number: string
    ): Promise<InServiceNumberGetResult>;
  }

  // Lidbs

  namespace Lidbs {
    type LidbsCreateItem = {
      customerOrderId: string;
      lidbTnGroups: {
        lidbTnGroup: Array<{
          telephoneNumbers: {
            telephoneNumber: Array<string>;
          };
          subscriberInformation: string;
          useType: 'RESIDENTIAL' | 'BUSINESS';
          visibility: 'PUBLIC' | 'PRIVATE';
        }>;
      };
    };

    function create(item: LidbsCreateItem, callback: Callback<unknown>): void;
    function create(
      client: Client,
      item: LidbsCreateItem,
      callback: Callback<unknown>
    ): void;

    function createAsync(item: LidbsCreateItem): Promise<unknown>;
    function createAsync(
      client: Client,
      item: LidbsCreateItem
    ): Promise<unknown>;

    function list(): void;

    function get(): void;
  }

  export function Lidbs(): void;

  // Order

  type OrderStatus = 'RECIEVED' | 'BACKORDERED' | 'COMPLETE' | 'PARTIAL' | 'FAILED';

  type CreateOrderType = {
    name: string;
    customerOrderId: string;
    siteId: string;
    peerId: string;
    existingTelephoneNumberOrderType: {
      telephoneNumberList: Array<{
        telephoneNumber: string;
      }>;
    };
  };

  type CreateOrderResult = {
    order: {
      customerOrderId: string;
      id: string;
      name: string;
      orderCreateDate: DateStr;
      backOrderRequested: boolean;
      ZIPSearchAndOrderType: {
        quantity: number;
        zip: number;
      };
      tnAttributes: Array<'Protected' | 'External' | 'Imported'>;
      partialAllowed: boolean;
      siteId: number;
    };
  };

  type OrderGetResult = {
    completedQuantity: number;
    createdByUser: string;
    errorList: number;
    failedNumbers: number;
    lastModifiedDate: DateStr;
    orderCompleteDate: DateStr;
    order: {
      orderCreateDate: DateStr;
      peerId: number;
      backOrderRequested: boolean;
      existingTelephoneNumberOrderType: {
        telephoneNumberList: { telephoneNumber: string };
      };
      partialAllowed: boolean;
      siteId: number;
      client: Client.Client;
    };
    orderStatus: OrderStatus;
    completedNumbers: { telephoneNumber: { fullNumber: string } };
    summary: string;
    failedQuantity: number;
  };

  type OrderListQuery = Query & {
    customerOrderId?: string;
    enddate?: string;
    status: OrderStatus;
    startdate?: string;
    userid?: string;
  };

  type OrderListResult = {
    listOrderIdUserIdDate: {
      totalCount: number;
      links: Links;
      orderIdUserIdDate: {
        accountId: number;
        countOfTNs: number;
        userId: string;
        lastModifiedDate: DateStr;
        orderDate: DateStr;
        orderType: 'new_number';
        orderId: string;
        orderStatus: OrderStatus;
        summary: string;
        telephoneNumberDetails: {
          states: { stateWithCount: { state: State; count: number } };
          rateCenters: {
            rateCenterWithCount: { count: number; rateCenter: string };
          };
          cities: { cityWithCount: { city: string; count: number } };
          tiers: { tierWithCount: { tier: Tier; count: number } };
          vendors: {
            vendorWithCount: {
              vendorId: VendorId;
              vendorName: VendorName;
              count: number;
            };
          };
        };
      };
    };
  };

  namespace Order {
    // create
    function create(
      order: CreateOrderType,
      callback: Callback<CreateOrderResult>
    ): void;
    function create(
      client: Client,
      order: CreateOrderType,
      callback: Callback<CreateOrderResult>
    ): void;

    function createAsync(order: CreateOrderType): Promise<CreateOrderResult>;
    function createAsync(
      client: Client,
      order: CreateOrderType
    ): Promise<CreateOrderResult>;

    // get
    function get(id: string, callback: Callback<OrderGetResult>): void;
    function get(
      client: Client,
      id: string,
      callback: Callback<OrderGetResult>
    ): void;

    function getAsync(id: string): Promise<OrderGetResult>;
    function getAsync(
      client: Client,
      id: string
    ): Promise<OrderGetResult>;

    // list
    function list(
      query: OrderListQuery,
      callback: Callback<OrderListResult>
    ): void;
    function list(
      client: Client,
      query: OrderListQuery,
      callback: Callback<OrderListResult>
    ): void;

    function listAsync(query: OrderListQuery): Promise<OrderListResult>;
    function listAsync(
      client: Client,
      query: OrderListQuery
    ): Promise<OrderListResult>;
  }

  export function Order(): undefined;

  // TN
  type TnStatus = 'Inservice' | string;

  type TnGetResult = {
    telephoneNumber: string;
    status: TnStatus;
    lastModifiedDate: DateStr;
    orderCreateDate: DateStr;
    orderId: string;
    orderType: 'NEW_NUMBER_ORDER' | string;
    inServiceDate: DateStr;
    siteId: number;
    accountId: number;
    client: Client.Client;
  };

  type TnListQuery = Query & {
    accountId?: string | number;
    city?: string;
    fullNumber?: string | number;
    host?: string;
    lata?: number;
    npa?: string | number;
    npaNxx?: string | number;
    rateCenter?: string;
    state?: State;
    tier?: Tier;
  };

  type TnListResult = {
    telephoneNumberCount: number;
    links: Links;
    telephoneNumbers: {
      telephoneNumber: Array<{
        city: string;
        lata: number;
        state: State;
        fullNumber: string;
        tier: Tier;
        vendorId: VendorId;
        status: TnStatus;
        accountId: number;
        lastModified: DateStr;
        client: Client.Client;
      }>;
    };
  };

  namespace Subscription {
    function get(id: string, callback: Callback<unknown>): void;
    function get(
      client: Client,
      id: string,
      callback: Callback<unknown>
    ): void;

    function getAsync(id: string): Promise<unknown>;
    function getAsync(client: Client, id: string): Promise<unknown>;

    function list(
      query: unknown,
      callback: Callback<Array<SubscriptionType>>
    ): void;
    function list(
      client: Client,
      query: unknown,
      callback: Callback<Array<SubscriptionType>>
    ): void;

    function listAsync(query: unknown): Promise<Array<SubscriptionType>>;
    function listAsync(
      client: Client,
      query: unknown
    ): Promise<Array<SubscriptionType>>;

    function create(
      item: CreateSubscriptionType,
      callback: Callback<SubscriptionType>
    ): void;
    function create(
      client: Client,
      item: CreateSubscriptionType,
      callback: Callback<SubscriptionType>
    ): void;

    function createAsync(
      item: CreateSubscriptionType
    ): Promise<SubscriptionType>;
    function createAsync(
      client: Client,
      item: CreateSubscriptionType
    ): Promise<SubscriptionType>;
  }

  export function Subscription(): void;

  export function Site(): void;
  export function SipPeer(): void;

  export const RateCenter: List<{}, {}>;

  export function TnReservation(): void;
  export function PortIn(): void;
  export function PortOut(): void;

  export const LnpChecker: {
    check: Array<unknown>;
    checkAsync: Array<unknown>;
  };

  export function User(): void;

  export function LsrOrder(): void;

  export function RemoveImportedTnOrder(): void;
}
