import { AppText as Text } from "./AppText";

/**
 * The "Rev" half of the RevCode lockup, matching the desktop sidebar's
 * RevWordmark (apps/web SidebarChrome.tsx).
 *
 * Sized to its sibling "Code" text rather than to a pixel height: the two are
 * rendered adjacent with no gap so they read as one word, which only works if
 * both share a type scale.
 */
export function RevWordmark(props: { readonly allowFontScaling?: boolean }) {
  return (
    <Text
      allowFontScaling={props.allowFontScaling}
      className="font-t3-bold text-[21px] tracking-[-0.5px] text-foreground"
    >
      Rev
    </Text>
  );
}
