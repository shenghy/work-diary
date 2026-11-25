import {
	createSSRApp
} from "vue";
import App from "./App.vue";
import { themeMixin } from "./utils/theme";
export function createApp() {
	const app = createSSRApp(App);
	app.mixin(themeMixin);
	return {
		app,
	};
}
