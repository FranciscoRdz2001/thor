import 'package:flutter/widgets.dart' show IconData;

/// Nombre legible de un ícono de Material (`arrow_back`, `shopping_cart`).
///
/// `IconData` solo trae un código (`U+E092`): como etiqueta de un toque no
/// dice nada. Flutter no expone el nombre en ejecución, así que se
/// resuelve contra los íconos que una app usa para navegar y accionar
/// (atrás, cerrar, menú, carrito, chat…). Los que no están salen como
/// `icono:e092`, igual de buscables en la fuente de íconos.
///
/// La tabla son códigos literales (no referencias a `Icons.*`): así no
/// obliga al tree-shaking de la fuente de íconos a conservar esos glifos
/// en el build de la app.
abstract final class IconNames {
  /// Etiqueta del [icon]: `icono:<nombre>` o `icono:<código hex>`.
  static String labelOf(IconData icon) {
    final name = switch (icon.fontFamily) {
      'MaterialIcons' => _names[icon.codePoint],
      _ => null,
    };
    return 'icono:${name ?? icon.codePoint.toRadixString(16)}';
  }

  static const Map<int, String> _names = {
    0xe092: 'arrow_back',
    0xe093: 'arrow_back_ios',
    0xe094: 'arrow_back_ios_new',
    0xe09b: 'arrow_forward',
    0xe09c: 'arrow_forward_ios',
    0xe0a0: 'arrow_upward',
    0xe097: 'arrow_downward',
    0xe098: 'arrow_drop_down',
    0xe15e: 'chevron_left',
    0xe15f: 'chevron_right',
    0xe353: 'keyboard_arrow_down',
    0xe356: 'keyboard_arrow_up',
    0xe354: 'keyboard_arrow_left',
    0xe355: 'keyboard_arrow_right',
    0xe246: 'expand_more',
    0xe245: 'expand_less',
    0xe16a: 'close',
    0xe168: 'clear',
    0xe139: 'cancel',
    0xe156: 'check',
    0xe1f6: 'done',
    0xe3dc: 'menu',
    0xe404: 'more_vert',
    0xe402: 'more_horiz',
    0xe567: 'search',
    0xe280: 'filter_list',
    0xe683: 'tune',
    0xe5d2: 'sort',
    0xe514: 'refresh',
    0xe047: 'add',
    0xe516: 'remove',
    0xe1b9: 'delete',
    0xe1bb: 'delete_outline',
    0xe21a: 'edit',
    0xe593: 'share',
    0xe571: 'send',
    0xe190: 'content_copy',
    0xe201: 'download',
    0xe695: 'upload',
    0xe318: 'home',
    0xf107: 'home_outlined',
    0xe491: 'person',
    0xe497: 'person_outline',
    0xe043: 'account_circle',
    0xe041: 'account_balance_wallet',
    0xe25b: 'favorite',
    0xe25c: 'favorite_border',
    0xe5f9: 'star',
    0xe5fa: 'star_border',
    0xe0f1: 'bookmark',
    0xe0f4: 'bookmark_border',
    0xe59c: 'shopping_cart',
    0xf37f: 'shopping_cart_outlined',
    0xe59a: 'shopping_bag',
    0xf37d: 'shopping_bag_outlined',
    0xe60a: 'store',
    0xe3a6: 'local_shipping',
    0xe39c: 'local_offer',
    0xe148: 'category',
    0xe384: 'list',
    0xe2ea: 'grid_view',
    0xe153: 'chat',
    0xe155: 'chat_bubble_outline',
    0xe3e0: 'message',
    0xe621: 'support_agent',
    0xe302: 'headset_mic',
    0xe4a2: 'phone',
    0xe3c3: 'mail',
    0xe3c4: 'mail_outline',
    0xe44f: 'notifications',
    0xe451: 'notifications_none',
    0xe57f: 'settings',
    0xe33c: 'info',
    0xe33d: 'info_outline',
    0xe30b: 'help_outline',
    0xe6bd: 'visibility',
    0xe6be: 'visibility_off',
    0xe3ae: 'lock',
    0xe3b3: 'logout',
    0xe3ab: 'location_on',
    0xe130: 'camera_alt',
    0xe3e1: 'mic',
    0xe4f5: 'qr_code',
    0xe4f7: 'qr_code_scanner',
    0xe19f: 'credit_card',
    0xe481: 'payment',
    0xe50c: 'receipt',
    0xe314: 'history',
    0xe122: 'calendar_today',
    0xe366: 'language',
    0xe65b: 'thumb_up',
  };
}
