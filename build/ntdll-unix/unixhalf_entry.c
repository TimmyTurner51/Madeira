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
