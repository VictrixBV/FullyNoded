//
//  Signer.swift
//  BitSense
//
//  Created by Peter on 28/06/20.
//  Copyright © 2020 Fontaine. All rights reserved.
//

import Foundation
import LibWally

class PSBTSigner {
    
    class func sign(psbt: String, completion: @escaping ((success: Bool, psbt: String?, rawTx: String?)) -> Void) {
        
        var seedsToSignWith = [[String:Any]]()
        var xprvsToSignWith = [HDKey]()
        var psbtToSign:PSBT!
        var chain:Network!
        
        func reset() {
            seedsToSignWith.removeAll()
            xprvsToSignWith.removeAll()
            psbtToSign = nil
            chain = nil
        }
        
        func finalizeWithBitcoind() {
            Reducer.makeCommand(command: .finalizepsbt, param: "\"\(psbtToSign.description)\"") { (object, errorDescription) in
                if let result = object as? NSDictionary {
                    if let complete = result["complete"] as? Bool {
                        if complete {
                            let hex = result["hex"] as! String
                            reset()
                            completion((true, nil, hex))
                        } else {
                            let psbt = result["psbt"] as! String
                            reset()
                            completion((true, psbt, nil))
                        }
                    } else {
                        reset()
                        completion((false, nil, errorDescription))
                    }
                } else {
                    reset()
                    completion((false, nil, errorDescription))
                }
            }
        }
        
        func processWithActiveWallet() {
            Reducer.makeCommand(command: .walletprocesspsbt, param: "\"\(psbtToSign.description)\", true, \"ALL\", true") { (object, errorDescription) in
                if let dict = object as? NSDictionary {
                    if let processedPsbt = dict["psbt"] as? String {
                        do {
                            psbtToSign = try PSBT(processedPsbt, chain)
                            if xprvsToSignWith.count > 0 {
                                attemptToSignLocally()
                            } else {
                                finalizeWithBitcoind()
                            }
                        } catch {
                            if xprvsToSignWith.count > 0 {
                                attemptToSignLocally()
                            } else {
                                finalizeWithBitcoind()
                            }
                        }
                    }
                } else {
                    reset()
                    completion((false, nil, nil))
                }
            }
        }
        
        func attemptToSignLocally() {
            /// Need to ensure similiar seeds do not sign mutliple times. This can happen if a user adds the same seed multiple times.
            var xprvStrings = [String]()
            for xprv in xprvsToSignWith {
                xprvStrings.append(xprv.description)
                
            }
            xprvsToSignWith.removeAll()
            let uniqueXprvs = Array(Set(xprvStrings))
            for uniqueXprv in uniqueXprvs {
                if let xprv = HDKey(uniqueXprv) {
                    xprvsToSignWith.append(xprv)
                }
            }
            if xprvsToSignWith.count > 0 {
                var signableKeys = [String]()
                for (i, key) in xprvsToSignWith.enumerated() {
                    let inputs = psbtToSign.inputs
                    for (x, input) in inputs.enumerated() {
                        /// Create an array of child keys that we know can sign our inputs.
                        if let origins: [PubKey : KeyOrigin] = input.canSign(key) {
                            for origin in origins {
                                if let childKey = try? key.derive(origin.value.path) {
                                    if let privKey = childKey.privKey {
                                        precondition(privKey.pubKey == origin.key)
                                        signableKeys.append(privKey.wif)
                                    }
                                }
                            }
                        }
                        /// Once the above loops complete we remove an duplicate signing keys from the array then sign the psbt with each unique key.
                        if i + 1 == xprvsToSignWith.count && x + 1 == inputs.count {
                            let uniqueSigners = Array(Set(signableKeys))
                            if uniqueSigners.count > 0 {
                                for (s, signer) in uniqueSigners.enumerated() {
                                    if let signingKey = Key(signer, chain) {
                                        psbtToSign.sign(signingKey)
                                        /// Once we completed the signing loop we finalize with our node.
                                        if s + 1 == uniqueSigners.count {
                                            finalizeWithBitcoind()
                                        }
                                    }
                                }
                            } else {
                                finalizeWithBitcoind()
                            }
                        }
                    }
                }
            }
        }
        
        /// Fetch keys to sign with
        func getKeysToSignWith() {
            xprvsToSignWith.removeAll()
            for (i, seed) in seedsToSignWith.enumerated() {
                let encryptedSeed = seed["words"] as! Data
                Crypto.decryptData(dataToDecrypt: encryptedSeed) { (seed) in
                    if seed != nil {
                        if let words = String(data: seed!, encoding: .utf8) {
                            if let masterKey = CreateFullyNodedWallet.masterKey(words: words) {
                                if let hdkey = HDKey(masterKey) {
                                    xprvsToSignWith.append(hdkey)
                                }
                            }
                        }
                    }
                }
                if i + 1 == seedsToSignWith.count {
                    processWithActiveWallet()
                }
            }
        }
        
        /// Fetch wallets on the same network
        func getSeeds() {
            seedsToSignWith.removeAll()
            CoreDataService.retrieveEntity(entityName: .signers) { seeds in
                if seeds != nil {
                    if seeds!.count > 0 {
                        for (i, seed) in seeds!.enumerated() {
                            seedsToSignWith.append(seed)
                            if i + 1 == seeds!.count {
                                getKeysToSignWith()
                            }
                        }
                    } else {
                        processWithActiveWallet()
                    }
                }
            }
        }
                
        getSeeds()
    }
    
}

