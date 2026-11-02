import Foundation

/// The native host supplies its ASCII-capable layout at the event boundary. App code consumes the same
/// virtual-key contract on every platform, without knowing about Qt or the window-system keyboard backend.
public enum NSKeyboardLayout {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var characters: [UInt32: String] = {
        let keys: [(UInt16, String, String)] = [
            (0,"a","A"),(1,"s","S"),(2,"d","D"),(3,"f","F"),(4,"h","H"),(5,"g","G"),
            (6,"z","Z"),(7,"x","X"),(8,"c","C"),(9,"v","V"),(11,"b","B"),(12,"q","Q"),
            (13,"w","W"),(14,"e","E"),(15,"r","R"),(16,"y","Y"),(17,"t","T"),
            (18,"1","!"),(19,"2","@"),(20,"3","#"),(21,"4","$"),(22,"6","^"),(23,"5","%"),
            (24,"=","+"),(25,"9","("),(26,"7","&"),(27,"-","_"),(28,"8","*"),(29,"0",")"),
            (30,"]","}"),(31,"o","O"),(32,"u","U"),(33,"[","{"),(34,"i","I"),(35,"p","P"),
            (37,"l","L"),(38,"j","J"),(39,"'","\""),(40,"k","K"),(41,";",":"),(42,"\\","|"),
            (43,",","<"),(44,"/","?"),(45,"n","N"),(46,"m","M"),(47,".",">"),(49," "," "),(50,"`","~")]
        return Dictionary(uniqueKeysWithValues: keys.flatMap { code, normal, shifted in
            [(UInt32(code) << 1, normal), ((UInt32(code) << 1) | 1, shifted)]
        })
    }()

    public static func latinCharacter(for keyCode: UInt16, shift: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        return characters[(UInt32(keyCode) << 1) | (shift ? 1 : 0)]
    }

    public static func recordLatinCharacter(_ character: String, for keyCode: UInt16, shift: Bool) {
        guard !character.isEmpty, character.unicodeScalars.allSatisfy(\.isASCII) else { return }
        lock.lock(); defer { lock.unlock() }
        characters[(UInt32(keyCode) << 1) | (shift ? 1 : 0)] = character
    }
}
