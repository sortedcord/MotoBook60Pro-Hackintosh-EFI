/*
 * SSDT-PS2VIS: keep the PS/2 keyboard visible on macOS. Needs the DSDT from tools/make_acpi_tables.py
 * (change C10 renames \_SB.PC00.LPCB.PS2K._STA to XSTA).
 */
DefinitionBlock ("", "SSDT", 2, "MB60P", "PS2VIS", 0x00000001)
{
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)
    External (_SB_.PC00.LPCB.PS2K.XSTA, MethodObj)    // 0 Arguments

    If (CondRefOf (\_SB.PC00.LPCB.PS2K.XSTA))
    {
        Scope (\_SB.PC00.LPCB.PS2K)
        {
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }

                Return (\_SB.PC00.LPCB.PS2K.XSTA ())
            }
        }
    }
}
