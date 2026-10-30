// Local preview only. Production entry remains src/index.js.
import worker from './index.js';
export default {fetch(request,env){const url=new URL(request.url);url.protocol='https:';url.hostname='help.oathwallet.org';url.port='';return worker.fetch(new Request(url,request),env);}};
