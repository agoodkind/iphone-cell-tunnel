//
//  Tuist.swift
//  CellTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import ProjectDescription

let tuist = Tuist(
  project: .tuist(
    generationOptions: .options(
      disableSandbox: false,
      includeGenerateScheme: true
    )
  )
)
