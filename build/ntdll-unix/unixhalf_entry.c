/*
 * The dylib's public surface: three accessors, nothing else.
 *
 * The unix half is compiled with -fvisibility=hidden, so its own entry points cannot be
 * exported from a shared image even when named in an export list. Rather than relax that
 * flag for the whole half (which would export every internal symbol and let the dylib
 * interpose on the app), this file is the one default-visible object in the image. It
 * forwards to the hidden symbols, which it can reach because it is linked into the same
 * dylib.
 *
 * `madeira_` prefix on purpose: the archive copy of the half is still linked into the app
 * as the fallback, and these must never collide with anything the app or Wine defines.
 *
 *   madeira_unix_half_main                 -> __wine_main( argc, argv )
 *   madeira_unix_half_log_set_file(path)   -> wine_log_set_file( path )
 *   madeira_unix_half_main_i386_addr()     -> &ios_main_image_i386
 *   madeira_unix_half_live_game_children() -> madeira_live_game_children()
 *
 * The third is a write target: the app sets the main image's machine before starting Wine
 * so the unix side reserves the WoW64 guest window before its first TEB. Because the flag
 * lives in the half, a caller that wrote the app's linked copy would be writing to a
 * variable this image never reads.
 *
 * The fourth is the same problem in the other direction, and it was measured: the child
 * table (process_ios.c) is filled by spawn_process, which is unix side, so it is filled in
 * THIS image; WineProcessBridge.m read it through the archive's copy, which is a different
 * array that is always empty while a component is installed. MADEIRA_WAIT_CHILDREN and the
 * launcher-stub protection therefore did nothing in a Dock session (FH6: dockhost.exe
 * exited, the game was still loading, and the session ended anyway). Read through here.
 */

void __wine_main( int argc, char *argv[] );
void wine_log_set_file( const char *path );
extern int ios_main_image_i386;

__attribute__((visibility("default")))
void madeira_unix_half_main( int argc, char *argv[] )
{
    __wine_main( argc, argv );
}

__attribute__((visibility("default")))
void madeira_unix_half_log_set_file( const char *path )
{
    wine_log_set_file( path );
}

__attribute__((visibility("default")))
int *madeira_unix_half_main_i386_addr( void )
{
    return &ios_main_image_i386;
}

/* The child table lives in this image (spawn_process is unix side), so a reader in the app
 * must come through here or it reads an empty array of its own. Same signature and meaning
 * as madeira_live_game_children in process_ios.c. */
int madeira_live_game_children( char *buf, int len, double max_age );

__attribute__((visibility("default")))
int madeira_unix_half_live_game_children( char *buf, int len, double max_age )
{
    return madeira_live_game_children( buf, len, max_age );
}

/* Winios.m <-> win32u-unix bridge: win32u lives inside this dylib alongside ntdll, so
 * window-handle tables, input injection, and census lookups must target this image's
 * win32u rather than the app's statically linked fallback archive (whose handle table
 * is NULL while a UnixHalf component runs). */
int winios_drv_census_owner( void *hwnd, unsigned int *pid, unsigned int *style );
int winios_drv_process_image( unsigned int pid, char *out, unsigned int size );
int winios_drv_post_restore( void *hwnd );
int winios_drv_foreground_if_owner( void *hwnd );
int winios_drv_close_desktop_if_owner( void );
void winios_drv_post_mouse( int x, int y, unsigned int flags, unsigned int mouse_data, void *hwnd );
void winios_drv_post_key( unsigned short vk, unsigned int flags );
void winios_drv_post_text( unsigned int scalar, unsigned short vk, int shift );
int winios_drv_size_game_window( void *hwnd, int width, int height );
void winios_dump_window_tree( void );
void ios_dump_all_thread_stacks( void );

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_census_owner( void *hwnd, unsigned int *pid, unsigned int *style )
{
    return winios_drv_census_owner( hwnd, pid, style );
}

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_process_image( unsigned int pid, char *out, unsigned int size )
{
    return winios_drv_process_image( pid, out, size );
}

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_post_restore( void *hwnd )
{
    return winios_drv_post_restore( hwnd );
}

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_foreground_if_owner( void *hwnd )
{
    return winios_drv_foreground_if_owner( hwnd );
}

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_close_desktop_if_owner( void )
{
    return winios_drv_close_desktop_if_owner();
}

__attribute__((visibility("default")))
void madeira_unix_half_winios_drv_post_mouse( int x, int y, unsigned int flags, unsigned int mouse_data, void *hwnd )
{
    winios_drv_post_mouse( x, y, flags, mouse_data, hwnd );
}

__attribute__((visibility("default")))
void madeira_unix_half_winios_drv_post_key( unsigned short vk, unsigned int flags )
{
    winios_drv_post_key( vk, flags );
}

__attribute__((visibility("default")))
void madeira_unix_half_winios_drv_post_text( unsigned int scalar, unsigned short vk, int shift )
{
    winios_drv_post_text( scalar, vk, shift );
}

__attribute__((visibility("default")))
int madeira_unix_half_winios_drv_size_game_window( void *hwnd, int width, int height )
{
    return winios_drv_size_game_window( hwnd, width, height );
}

__attribute__((visibility("default")))
void madeira_unix_half_winios_dump_window_tree( void )
{
    winios_dump_window_tree();
}

__attribute__((visibility("default")))
void madeira_unix_half_ios_dump_all_thread_stacks( void )
{
    ios_dump_all_thread_stacks();
}

/* Wineserver half: bundled into libntdll_unix.dylib alongside ntdll_unix and win32u_unix
 * so madsync, madeira_sync_cells, ios_srv_direct_call, ios_wineserver_ring, ios_eco_gen,
 * ios_wait_reg, ios_hang_kill_pid, and madeira_dircache_changed all live in one image with
 * zero split-brain.
 *
 * madeira_unix_half_is_dylib=1 (hidden) tells server_ios.c and sync.c they are running
 * inside this dylib. If an older app binary loads this dylib without starting wineserver
 * through madeira_unix_half_wineserver_main, madeira_unix_half_wineserver_active stays 0
 * and server_ios.c / sync.c resolve ios_srv_direct_call, ios_wineserver_ring, and
 * madeira_sync_cells from the host app via dlsym(RTLD_DEFAULT, ...) for full backward
 * compatibility. */
__attribute__((visibility("hidden"))) int madeira_unix_half_is_dylib = 1;
__attribute__((visibility("hidden"))) volatile int madeira_unix_half_wineserver_active = 0;

int wineserver_main( int argc, char *argv[] );
void wineserver_log_set_file( const char *path );
void wineserver_set_nls_dir( const char *path );
void wineserver_inject_client_fd( int fd );
void wine_set_ui_log_callback( void (*cb)(const char *) );
extern int foreground;
extern int wineserver_ready;
extern volatile int ws_log_quiet;

__attribute__((visibility("default")))
int madeira_unix_half_wineserver_main( int argc, char *argv[] )
{
    __atomic_store_n( &madeira_unix_half_wineserver_active, 1, __ATOMIC_RELEASE );
    return wineserver_main( argc, argv );
}

__attribute__((visibility("default")))
void madeira_unix_half_wineserver_log_set_file( const char *path )
{
    __atomic_store_n( &madeira_unix_half_wineserver_active, 1, __ATOMIC_RELEASE );
    wineserver_log_set_file( path );
}

__attribute__((visibility("default")))
void madeira_unix_half_wineserver_set_nls_dir( const char *path )
{
    __atomic_store_n( &madeira_unix_half_wineserver_active, 1, __ATOMIC_RELEASE );
    wineserver_set_nls_dir( path );
}

__attribute__((visibility("default")))
void madeira_unix_half_wineserver_inject_client_fd( int fd )
{
    wineserver_inject_client_fd( fd );
}

__attribute__((visibility("default")))
int *madeira_unix_half_wineserver_foreground_addr( void )
{
    return &foreground;
}

__attribute__((visibility("default")))
int *madeira_unix_half_wineserver_ready_addr( void )
{
    return &wineserver_ready;
}

__attribute__((visibility("default")))
volatile int *madeira_unix_half_wineserver_log_quiet_addr( void )
{
    return &ws_log_quiet;
}

__attribute__((visibility("default")))
void madeira_unix_half_wineserver_set_ui_log_callback( void (*cb)(const char *) )
{
    wine_set_ui_log_callback( cb );
}
